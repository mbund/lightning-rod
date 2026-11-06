package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Blocks;

final class OcclusionFixture extends Fixture {
    private static final BlockPos DEEP = new BlockPos(20, -32, 20);
    private static final BlockPos SEALED = new BlockPos(20, -1, 20);
    private static final BlockPos MARKER = new BlockPos(20, 16, 20);
    private static final BlockPos LID = new BlockPos(20, 15, 20);
    private static final net.minecraft.world.level.block.Block[] BLOCK_ENTITIES = {
        Blocks.SPAWNER, Blocks.TRIAL_SPAWNER, Blocks.VAULT, Blocks.BEE_NEST, Blocks.BEEHIVE
    };
    private long started;
    private String phase = "surface";
    private boolean acknowledged;
    private int columnPacketsBeforeFloor;
    private final java.util.concurrent.atomic.AtomicInteger columnPackets = new java.util.concurrent.atomic.AtomicInteger();
    private final java.util.concurrent.atomic.AtomicInteger concealedSectionBlockUpdates = new java.util.concurrent.atomic.AtomicInteger();

    OcclusionFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }

    @Override void connected(Minecraft game) {
        var channel = ((dev.lightningrod.e2e.mixin.ClientConnectionAccessor) game.getConnection().getConnection()).lightningRod$channel();
        if (channel.pipeline().get("occlusion_probe") != null) return;
        channel.pipeline().addBefore("packet_handler", "occlusion_probe", new io.netty.channel.ChannelInboundHandlerAdapter() {
            @Override public void channelRead(io.netty.channel.ChannelHandlerContext context, Object message) throws Exception {
                if (message instanceof net.minecraft.network.protocol.game.ClientboundLevelChunkWithLightPacket packet
                        && packet.getX() == 1 && packet.getZ() == 1) columnPackets.incrementAndGet();
                if (message instanceof net.minecraft.network.protocol.game.ClientboundSectionBlocksUpdatePacket packet) {
                    packet.runUpdates((position, state) -> {
                        if (position.getX() >> 4 == 1 && position.getZ() >> 4 == 1
                                && position.getY() >= -16 && position.getY() < 0) concealedSectionBlockUpdates.incrementAndGet();
                    });
                }
                super.channelRead(context, message);
            }
        });
    }

    @Override int renderDistance() { return 2; }
    @Override boolean prepare(Minecraft game) { return true; }

    @Override void message(String text) {
        phase = text;
        acknowledged = false;
    }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || r.terrainTick < 0) return;
        if (started == 0) started = System.nanoTime();
        if (System.nanoTime() - started > 60_000_000_000L) {
            client.fail("occlusion_timeout_" + phase + "_marker_" + game.level.getBlockState(MARKER)
                    + "_entities_" + visibleEntities(game) + "_block_entities_" + blockEntitiesMatch(game, true));
            return;
        }
        if (acknowledged || loaded < 25 || missing != 0) return;
        var marker = game.level.getBlockState(MARKER);
        boolean alice = r.peer.equals("alice");
        switch (phase) {
            case "surface" -> {
                if (!marker.is(Blocks.AIR) || visibleEntities(game) != 0) { client.fail("underground_disclosed_at_surface"); return; }
                if (!blockEntitiesMatch(game, false)) { client.fail("block_entity_section_disclosed_at_surface"); return; }
                if (!client.screenshot("occlusion_surface").done()) return;
                acknowledged = true;
                client.send("surface_checked");
            }
            case "entered" -> {
                if (alice && game.player.getY() < 16) { client.fail("teleport_arrived_before_destination_floor"); return; }
                if (!alice || !close(game.player.getY(), 17, 0.1) || !marker.is(Blocks.GOLD_BLOCK) || visibleEntities(game) != 3) return;
                if (!blockEntitiesMatch(game, true)) { client.fail("block_entities_missing_inside_room"); return; }
                if (!client.screenshot("occlusion_inside").done()) return;
                acknowledged = true;
                client.send("inside_checked");
            }
            case "check_surface" -> {
                if (alice) return;
                if (!marker.is(Blocks.AIR) || visibleEntities(game) != 0 || !close(game.player.getY(), 65, 0.1)) {
                    client.fail("other_observer_disclosure_leaked");
                    return;
                }
                if (!client.screenshot("occlusion_isolated_surface").done()) return;
                acknowledged = true;
                client.send("open");
            }
            case "opened" -> {
                if (!marker.is(Blocks.GOLD_BLOCK)) return;
                if (alice && (visibleEntities(game) != 3 || !blockEntitiesMatch(game, true))) return;
                if (!alice && !close(game.player.getY(), 65, 0.1)) { client.fail("surface_observer_moved"); return; }
                if (!client.screenshot("occlusion_opened").done()) return;
                acknowledged = true;
                if (!game.level.getBlockState(SEALED).is(Blocks.AIR)) { client.fail("sealed_section_disclosed"); return; }
                if (!game.level.getBlockState(LID).is(Blocks.AIR)) { client.fail("section_beneath_closed_floor_disclosed"); return; }
                columnPacketsBeforeFloor = columnPackets.get();
                client.send("opened_checked");
            }
            case "lid_opened" -> {
                if (!game.level.getBlockState(LID).is(Blocks.IRON_BLOCK)) return;
                if (columnPackets.get() <= columnPacketsBeforeFloor) { client.fail("section_lid_missing_palette_update"); return; }
                if (!game.level.getBlockState(SEALED).is(Blocks.AIR)) { client.fail("sealed_section_disclosed_beneath_lid"); return; }
                if (!client.screenshot("occlusion_lid_update").done()) return;
                columnPacketsBeforeFloor = columnPackets.get();
                acknowledged = true;
                client.send("lid_checked");
            }
            case "floor_opened" -> {
                if (!game.level.getBlockState(SEALED).is(Blocks.EMERALD_BLOCK)) return;
                if (columnPackets.get() <= columnPacketsBeforeFloor) { client.fail("section_reveal_missing_palette_update"); return; }
                if (concealedSectionBlockUpdates.get() != 0) { client.fail("section_reveal_used_individual_block_updates"); return; }
                if (!game.level.getBlockState(DEEP).is(Blocks.AIR)) { client.fail("deep_section_disclosed"); return; }
                if (!client.screenshot("occlusion_section_update").done()) return;
                client.event("section_reveal", "chunk_packets", columnPackets.get() - columnPacketsBeforeFloor,
                        "individual_block_updates", concealedSectionBlockUpdates.get());
                columnPacketsBeforeFloor = columnPackets.get();
                acknowledged = true;
                client.send("floor_checked");
            }
            case "inside_block" -> {
                if (alice) {
                    if (!game.level.getBlockState(DEEP).is(Blocks.AIR)) { client.fail("other_observer_fallback_leaked"); return; }
                } else if (!game.level.getBlockState(DEEP).is(Blocks.AIR)) {
                    client.fail("opaque_observer_bypassed_concealment");
                    return;
                }
                if (!client.screenshot("occlusion_inside_block").done()) return;
                acknowledged = true;
                client.pass("concealment_entities_movement_edits_and_opaque_observer_verified");
            }
            default -> throw new IllegalArgumentException("unexpected occlusion phase: " + phase);
        }
    }
    private int visibleEntities(Minecraft game) {
        boolean item = false;
        boolean orb = false;
        for (var entity : game.level.entitiesForRendering()) {
            item |= entity instanceof net.minecraft.world.entity.item.ItemEntity && !entity.isRemoved();
            orb |= entity instanceof net.minecraft.world.entity.ExperienceOrb && !entity.isRemoved();
        }
        return (item ? 1 : 0) | (orb ? 2 : 0);
    }

    private boolean blockEntitiesMatch(Minecraft game, boolean disclosed) {
        for (int index = 0; index < BLOCK_ENTITIES.length; index++) {
            var state = game.level.getBlockState(new BlockPos(24 + index, 17, 24));
            if (!state.is(disclosed ? BLOCK_ENTITIES[index] : Blocks.AIR)) return false;
        }
        return true;
    }

}
