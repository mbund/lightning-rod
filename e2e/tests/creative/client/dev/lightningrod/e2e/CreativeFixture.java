package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.network.protocol.game.ClientboundBlockChangedAckPacket;
import net.minecraft.network.protocol.game.ClientboundBlockUpdatePacket;
import net.minecraft.network.protocol.game.ClientboundBundlePacket;
import net.minecraft.network.protocol.game.ClientboundSectionBlocksUpdatePacket;
import net.minecraft.network.protocol.game.ServerboundPlayerActionPacket;
import net.minecraft.network.protocol.game.ServerboundUseItemOnPacket;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;
import io.netty.channel.ChannelDuplexHandler;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelPromise;

final class CreativeFixture extends Fixture {
    private enum Phase { POSITION, GIVE, HELD, PLACE, PLACED, DROP_ONE, DROPPED_ONE, DROP_STACK, DROPPED_STACK, DROP_CATALOG, DROPPED_CATALOG, BREAK, BROKEN, COMPLETE }
    private Phase phase = Phase.POSITION;
    private static final BlockPos PLACED = new BlockPos(3, 65, 1);
    private volatile String predictionFailure;
    private volatile boolean placementAcknowledged;
    private volatile boolean breakingAcknowledged;

    CreativeFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }

    @Override void connected(Minecraft game) {
        if (!r.peer.equals("alice")) return;
        var channel = ((ClientConnectionAccessor) game.getConnection().getConnection()).lightningRod$channel();
        if (channel.pipeline().get("creative-prediction") != null) return;
        channel.pipeline().addBefore("packet_handler", "creative-prediction", new ChannelDuplexHandler() {
            private int placementSequence = -1;
            private int breakingSequence = -1;
            private boolean placementVerified;
            private boolean breakingVerified;

            @Override public void write(ChannelHandlerContext context, Object message, ChannelPromise promise) throws Exception {
                if (message instanceof ServerboundUseItemOnPacket packet && packet.getHitResult().getBlockPos().equals(PLACED.below())) {
                    placementSequence = packet.getSequence();
                    placementVerified = false;
                }
                if (message instanceof ServerboundPlayerActionPacket packet && packet.getPos().equals(PLACED)
                        && packet.getAction() == ServerboundPlayerActionPacket.Action.START_DESTROY_BLOCK) {
                    breakingSequence = packet.getSequence();
                    breakingVerified = false;
                }
                super.write(context, message, promise);
            }

            private void update(BlockPos position, BlockState state) {
                if (!position.equals(PLACED)) return;
                if (placementSequence >= 0 && state.is(Blocks.STONE)) placementVerified = true;
                if (breakingSequence >= 0 && state.isAir()) breakingVerified = true;
            }

            private void observe(Object message) {
                if (message instanceof ClientboundBundlePacket bundle) for (var packet : bundle.subPackets()) observe(packet);
                if (message instanceof ClientboundSectionBlocksUpdatePacket packet) packet.runUpdates(this::update);
                if (message instanceof ClientboundBlockUpdatePacket packet) update(packet.getPos(), packet.getBlockState());
                if (message instanceof ClientboundBlockChangedAckPacket packet) {
                    if (placementSequence >= 0 && packet.sequence() >= placementSequence && !placementAcknowledged) {
                        if (!placementVerified) predictionFailure = "placement_acknowledged_before_authoritative_block";
                        placementAcknowledged = true;
                    }
                    if (breakingSequence >= 0 && packet.sequence() >= breakingSequence && !breakingAcknowledged) {
                        if (!breakingVerified) predictionFailure = "breaking_acknowledged_before_authoritative_block";
                        breakingAcknowledged = true;
                    }
                }
            }

            @Override public void channelRead(ChannelHandlerContext context, Object message) throws Exception {
                observe(message);
                super.channelRead(context, message);
            }
        });
    }

    public void tick(Minecraft game, int loaded, int missing) {
        if (predictionFailure != null) { client.fail(predictionFailure); return; }
        if (r.terrainTick < 0 || missingChunks(game, 2) != 0) return;
        if (r.tick - r.terrainTick > 400) { client.fail("creative_timeout_stage_" + phase); return; }
        boolean alice = r.peer.equals("alice");
        if (phase == Phase.POSITION) {
            game.player.setPos(alice ? 0.5 : 8.5, 65, 3.5);
            game.player.setYRot(alice ? -90 : 90);
            game.player.setXRot(20);
            client.mark(r.peer + ".creative-ready");
            phase = Phase.GIVE;
        }
        for (String other : r.expectedPeers) if (!client.marked(other + ".creative-ready")) return;
        if (phase == Phase.GIVE) {
            if (alice) {
                var stack = new net.minecraft.world.item.ItemStack(net.minecraft.world.item.Items.STONE, 8);
                game.player.getInventory().setSelectedSlot(0);
                game.player.getInventory().setItem(0, stack);
                game.gameMode.handleCreativeModeItemAdd(stack, 36);
            }
            phase = Phase.HELD;
        }
        net.minecraft.world.entity.player.Player subject = null;
        for (var player : game.level.players()) if (player.getName().getString().equals("alice")) subject = player;
        if (subject == null) return;
        if (phase == Phase.HELD && subject.getMainHandItem().is(net.minecraft.world.item.Items.STONE) && subject.getMainHandItem().getCount() == 8) {
            if (!client.screenshot("creative_equipment").done()) return;
            client.mark(r.peer + ".creative-held");
            phase = Phase.PLACE;
        }
        BlockPos placed = PLACED;
        if (phase == Phase.PLACE) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".creative-held")) return;
            if (alice) game.gameMode.useItemOn(game.player, net.minecraft.world.InteractionHand.MAIN_HAND,
                new net.minecraft.world.phys.BlockHitResult(new net.minecraft.world.phys.Vec3(3.5, 65, 1.5), net.minecraft.core.Direction.UP, placed.below(), false));
            phase = Phase.PLACED;
        }
        if (phase == Phase.PLACED && game.level.getBlockState(placed).is(Blocks.STONE) && (!alice || placementAcknowledged)) {
            if (!client.screenshot("creative_block").done()) return;
            client.mark(r.peer + ".creative-placed");
            phase = Phase.DROP_ONE;
        }
        if (phase == Phase.DROP_ONE) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".creative-placed")) return;
            if (!game.level.getBlockState(placed).is(net.minecraft.world.level.block.Blocks.STONE)) { client.fail("creative_placement_reverted"); return; }
            if (alice) game.player.drop(false);
            phase = Phase.DROPPED_ONE;
        }
        int stone = 0;
        int bread = 0;
        for (var entity : game.level.entitiesForRendering()) if (entity instanceof net.minecraft.world.entity.item.ItemEntity item) {
            if (item.getItem().is(net.minecraft.world.item.Items.STONE)) stone += item.getItem().getCount();
            if (item.getItem().is(net.minecraft.world.item.Items.BREAD)) bread += item.getItem().getCount();
        }
        if (phase == Phase.DROPPED_ONE && stone == 1 && subject.getMainHandItem().getCount() == 7) {
            client.mark(r.peer + ".creative-dropped-one");
            phase = Phase.DROP_STACK;
        }
        if (phase == Phase.DROP_STACK) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".creative-dropped-one")) return;
            if (alice) game.player.drop(true);
            phase = Phase.DROPPED_STACK;
        }
        if (phase == Phase.DROPPED_STACK && stone == 8 && subject.getMainHandItem().isEmpty()) {
            client.mark(r.peer + ".creative-dropped-stack");
            phase = Phase.DROP_CATALOG;
        }
        if (phase == Phase.DROP_CATALOG) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".creative-dropped-stack")) return;
            if (alice) game.gameMode.handleCreativeModeItemDrop(new net.minecraft.world.item.ItemStack(net.minecraft.world.item.Items.BREAD, 4));
            phase = Phase.DROPPED_CATALOG;
        }
        if (phase == Phase.DROPPED_CATALOG && bread == 4 && stone == 8) {
            if (!client.screenshot("creative_drops").done()) return;
            client.event("creative_verified", "stone_dropped", stone, "bread_dropped", bread, "held_empty", subject.getMainHandItem().isEmpty());
            client.mark(r.peer + ".creative-done");
            phase = Phase.BREAK;
        }
        if (phase == Phase.BREAK) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".creative-done")) return;
            if (alice) game.gameMode.startDestroyBlock(placed, net.minecraft.core.Direction.UP);
            phase = Phase.BROKEN;
        }
        if (phase == Phase.BROKEN && game.level.getBlockState(placed).isAir() && (!alice || breakingAcknowledged)) {
            client.mark(r.peer + ".creative-broken");
            phase = Phase.COMPLETE;
        }
        if (phase == Phase.COMPLETE) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".creative-broken")) return;
            client.pass("creative_inventory_placement_equipment_and_drops_synchronized");
        }
    }

}
