package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.network.protocol.game.ServerboundMovePlayerPacket;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;

final class ItemsFixture extends Fixture {
    private static final int BREAD_COUNT = 17;
    private enum Phase {
        READY, CREATE, SPAWNED, SPAWN_OBSERVED, MERGED,
        PICKUP, COLLECTED, CHECK, CHECKED,
        MINING_READY, HAND_MINED, PICKAXE_READY, PICKAXE_MINED,
        PLACEMENT_READY, PLACE, PLACED, RELOAD_READY,
        RELOADED, COMPLETE
    }
    private Phase phase = Phase.READY;
    private boolean aimedAfterReload;
    private int mergedEntity = -1;
    private int breakingStages;
    private boolean breakingCleared;
    private boolean sawMiningSwing;

    ItemsFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return !r.scenario.equals("items-plaintext"); }

    public void tick(Minecraft game, int loaded, int missing) {
        if (r.scenario.equals("items-plaintext")) {
            var channel = ((ClientConnectionAccessor) game.getConnection().getConnection()).lightningRod$channel();
            if (channel.pipeline().get("encrypt") != null || channel.pipeline().get("decrypt") != null) {
                client.fail("plaintext_connection_encrypted");
                return;
            }
        }
        if (r.terrainTick < 0 || missingChunks(game, 2) != 0) return;
        if (r.tick - r.terrainTick > 600) { client.fail("items_timeout_stage_" + phase); return; }
        if (phase == Phase.HAND_MINED && r.peer.equals("bob")) {
            for (var player : game.level.players()) {
                if (player.getName().getString().equals("alice") && player.swinging && !sawMiningSwing) {
                    if (!client.screenshot("survival_mining_swing").done()) return;
                    sawMiningSwing = true;
                    client.event("survival_mining_swing_observed", "entity", player.getId());
                }
            }
        }
        if (phase == Phase.READY) {
            if (missing != 0) return;
            game.player.setPos(r.peer.equals("alice") ? 0.5 : 8.5, 65, 3.5);
            game.player.setYRot(r.peer.equals("alice") ? -125 : 125);
            game.player.setXRot(10);
            client.mark(r.peer + ".items-ready");
            phase = Phase.CREATE;
        }
        for (String other : r.expectedPeers) if (!client.marked(other + ".items-ready")) return;
        if (phase == Phase.CREATE) {
            if (r.peer.equals("alice")) client.send("items_create");
            phase = Phase.SPAWNED;
        }
        int count = 0;
        int total = 0;
        double highest = 0;
        net.minecraft.world.entity.item.ItemEntity last = null;
        for (var entity : game.level.entitiesForRendering()) if (entity instanceof net.minecraft.world.entity.item.ItemEntity item && !item.isRemoved()) {
            count++;
            total += item.getItem().getCount();
            highest = Math.max(highest, item.getY());
            last = item;
            if ((switch (phase) { case READY, CREATE, SPAWNED, SPAWN_OBSERVED, MERGED, PICKUP, COLLECTED, CHECK, CHECKED -> true; default -> false; }) && !item.getItem().is(net.minecraft.world.item.Items.BREAD)) { client.fail("wrong_item_type"); return; }
        }
        if ((phase == Phase.SPAWNED || phase == Phase.SPAWN_OBSERVED || phase == Phase.MERGED) && last != null) {
            var direction = last.getBoundingBox().getCenter().subtract(game.player.getEyePosition());
            game.player.setYRot((float)Math.toDegrees(Math.atan2(-direction.x, direction.z)));
            game.player.setXRot((float)Math.toDegrees(Math.atan2(-direction.y, Math.hypot(direction.x, direction.z))));
        }
        if (phase == Phase.SPAWNED && count == 2 && total == BREAD_COUNT && highest > 65.5) {
            if (!client.screenshot("items_spawned").done()) return;
            client.event("items_spawned", "entities", count, "total", total, "y", highest);
            client.mark(r.peer + ".items-spawned");
            phase = Phase.SPAWN_OBSERVED;
        }
        if (phase == Phase.SPAWN_OBSERVED) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".items-spawned")) return;
            if (r.peer.equals("alice")) client.send("items_release");
            phase = Phase.MERGED;
        }
        if (phase == Phase.MERGED && count == 1 && total == BREAD_COUNT && Math.abs(highest - 65) < 0.01) {
            mergedEntity = last.getId();
            if (!client.screenshot("items_merged").done()) return;
            client.event("items_merged", "entity", mergedEntity, "count", total, "y", highest);
            client.mark(r.peer + ".items-merged");
            phase = Phase.PICKUP;
        }
        if (phase == Phase.PICKUP) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".items-merged")) return;
            if (!game.levelRenderer.hasRenderedAllSections()) return;
            if (r.peer.equals("alice")) {
                game.player.setPos(4.5, 65, 0.5);
                game.getConnection().send(new ServerboundMovePlayerPacket.Pos(4.5, 65, 0.5, true, false));
            }
            phase = Phase.COLLECTED;
        }
        if (phase == Phase.COLLECTED && count == 0) {
            int held = game.player.getInventory().countItem(net.minecraft.world.item.Items.BREAD);
            if (held != (r.peer.equals("alice") ? BREAD_COUNT : 0)) return;
            if (!client.screenshot("items_collected").done()) return;
            client.mark(r.peer + ".items-collected");
            phase = Phase.CHECK;
        }
        if (phase == Phase.CHECK) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".items-collected")) return;
            client.send("items_check");
            phase = Phase.CHECKED;
        }
        if (phase == Phase.CHECKED && client.received("Items verified")) {
            if (r.peer.equals("alice")) client.send("items_mine_setup");
            phase = Phase.MINING_READY;
        }
        var first = new BlockPos(4, 65, -2);
        var second = new BlockPos(5, 65, -2);
        if (phase == Phase.MINING_READY && game.level.getBlockState(first).is(net.minecraft.world.level.block.Blocks.STONE)) {
            if (r.peer.equals("alice")) {
                org.lwjgl.glfw.GLFW.glfwFocusWindow(ClientApi.window(game));
                game.mouseHandler.grabMouse();
                if (!game.mouseHandler.isMouseGrabbed()) return;
                game.options.keyAttack.setDown(false);
            }
            client.mark(r.peer + ".mining-ready");
            phase = Phase.HAND_MINED;
            return;
        }
        if (phase == Phase.HAND_MINED) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".mining-ready")) return;
            if (game.level.getBlockState(first).isAir()) {
                game.options.keyAttack.setDown(false);
                if (!client.received("Hand mining verified")) return;
                if (count != 0) { client.fail("wrong_tool_dropped_stone"); return; }
                if (r.peer.equals("bob") && !sawMiningSwing) { client.fail("survival_mining_arm_did_not_swing"); return; }
                if (r.peer.equals("bob") && (breakingStages != 1023 || !breakingCleared)) return;
                client.event("hand_mining_verified", "stages", breakingStages);
                client.mark(r.peer + ".hand-mined");
                phase = Phase.PICKAXE_READY;
            } else if (r.peer.equals("alice")) {
                game.player.getInventory().setSelectedSlot(0);
                game.player.setYRot(180);
                game.player.setXRot((float)Math.toDegrees(Math.atan2(game.player.getEyeY() - 65.5, 2)));
                game.options.keyAttack.setDown(true);
            }
        }
        if (phase == Phase.PICKAXE_READY) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".hand-mined")) return;
            if (r.peer.equals("alice")) {
                game.player.getInventory().setSelectedSlot(1);
                game.gameMode.stopDestroyBlock();
            }
            phase = Phase.PICKAXE_MINED;
        }
        if (phase == Phase.PICKAXE_MINED) {
            if (!game.level.getBlockState(second).isAir() && r.peer.equals("alice")) {
                game.player.setYRot((float)Math.toDegrees(Math.atan2(-1, -2)));
                game.player.setXRot((float)Math.toDegrees(Math.atan2(game.player.getEyeY() - 65.5, Math.sqrt(5))));
                game.options.keyAttack.setDown(true);
            }
            if (game.level.getBlockState(second).isAir() && count == 1 && last.getItem().is(net.minecraft.world.item.Items.COBBLESTONE)) {
                game.options.keyAttack.setDown(false);
                if (!client.received("Pickaxe mining verified")) return;
                if (r.peer.equals("alice") && game.player.getInventory().getItem(1).getDamageValue() != 1) return;
                if (!client.screenshot("mining_drop").done()) return;
                client.event("pickaxe_mining_verified", "drop_count", last.getItem().getCount());
                client.mark(r.peer + ".mining-done");
                phase = Phase.PLACEMENT_READY;
            }
        }
        if (phase == Phase.PLACEMENT_READY) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".mining-done")) return;
            if (r.peer.equals("alice")) client.send("items_place_setup");
            phase = Phase.PLACE;
        }
        var placed = new BlockPos(3, 65, -1);
        if (phase == Phase.PLACE) {
            if (r.peer.equals("alice")) {
                int slot = -1;
                for (int i = 0; i < 9; i++) if (game.player.getInventory().getItem(i).is(net.minecraft.world.item.Items.DIRT)) slot = i;
                if (slot < 0) return;
                game.player.getInventory().setSelectedSlot(slot);
                game.gameMode.useItemOn(game.player, net.minecraft.world.InteractionHand.MAIN_HAND,
                    new net.minecraft.world.phys.BlockHitResult(new net.minecraft.world.phys.Vec3(3.5, 65, -0.5), net.minecraft.core.Direction.UP, placed.below(), false));
            }
            phase = Phase.PLACED;
        }
        if (phase == Phase.PLACED && game.level.getBlockState(placed).is(net.minecraft.world.level.block.Blocks.DIRT)) {
            if (!game.levelRenderer.hasRenderedAllSections()) return;
            if (r.peer.equals("alice") && game.player.getInventory().countItem(net.minecraft.world.item.Items.DIRT) != 7) return;
            lookAt(game, placed);
            if (!client.screenshot("survival_block_placed").done()) return;
            client.mark(r.peer + ".survival-placed");
            phase = Phase.RELOAD_READY;
        }
        if (phase == Phase.RELOAD_READY) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".survival-placed")) return;
            if (r.peer.equals("alice")) client.send("items_reload");
            phase = Phase.RELOADED;
        }
        if (phase == Phase.RELOADED && r.joins == 2 && game.level.players().size() == 2) {
            if (!game.level.getBlockState(placed).is(net.minecraft.world.level.block.Blocks.DIRT)) {
                client.fail("survival_placement_lost_after_reload"); return;
            }
            if (!game.level.getBlockState(first).isAir() || !game.level.getBlockState(second).isAir()) {
                client.fail("survival_mining_lost_after_reload"); return;
            }
            if (r.peer.equals("alice") && game.player.getInventory().countItem(net.minecraft.world.item.Items.DIRT) != 7) return;
            if (!aimedAfterReload) {
                aimedAfterReload = true;
                lookAt(game, placed);
            }
            if (!game.levelRenderer.hasRenderedAllSections()) return;
            if (!client.screenshot("survival_blocks_after_reload").done()) return;
            client.mark(r.peer + ".survival-restored");
            phase = Phase.COMPLETE;
        }
        if (phase == Phase.COMPLETE) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".survival-restored")) return;
            client.pass("survival_mining_swing_placement_and_reload_verified");
        }
    }

    private static void lookAt(Minecraft game, BlockPos position) {
        double dx = position.getX() + 0.5 - game.player.getX();
        double dz = position.getZ() + 0.5 - game.player.getZ();
        game.player.setYRot((float)Math.toDegrees(Math.atan2(-dx, dz)));
        game.player.setXRot((float)Math.toDegrees(Math.atan2(game.player.getEyeY() - position.getY() - 0.5, Math.hypot(dx, dz))));
    }

    @Override public void blockBreaking(BlockPos position, int stage) {
        if (!position.equals(new BlockPos(4, 65, -2))) return;
        if (stage >= 0 && stage < 10) breakingStages |= 1 << stage;
        else breakingCleared = true;
        client.event("block_breaking", "stage", stage);
    }
}
