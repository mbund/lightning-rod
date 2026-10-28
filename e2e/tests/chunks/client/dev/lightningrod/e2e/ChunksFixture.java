package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;

final class ChunksFixture extends Fixture {
    private long targetTick = -1;
    private boolean stampRequested;
    private boolean readsPaused;
    private boolean readsResumed;

    ChunksFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return r.scenario.contains("encrypted"); }
    @Override int renderDistance() { return 32; }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (loaded >= r.targetChunks && missing == 0 && r.terrainTick >= 0) {
            if (r.scenario.equals("chunks-simulations-multi")) {
                if (game.level.players().size() != 1 || game.getConnection().getOnlinePlayers().size() != 1) {
                    client.fail("simulation_players_leaked");
                    return;
                }
                var stack = game.player.getInventory().getItem(0);
                if (r.peer.equals("alice") ? !stack.is(net.minecraft.world.item.Items.BREAD) || stack.getCount() != 17 : !stack.isEmpty()) {
                    client.fail("simulation_inventory_leaked");
                    return;
                }
            }
            if (targetTick < 0) targetTick = client.streamTarget(loaded);
            if (r.tick - targetTick >= r.minimumSoakTicks) {
                if (r.scenario.startsWith("chunks-prepare") && !stampRequested) {
                    client.send("chunks_stamp");
                    stampRequested = true;
                    return;
                }
                if (r.scenario.startsWith("chunks-prepare") || r.scenario.startsWith("chunks-disk")) {
                    var blocks = new net.minecraft.world.level.block.Block[]{
                        net.minecraft.world.level.block.Blocks.GOLD_BLOCK,
                        net.minecraft.world.level.block.Blocks.DIAMOND_BLOCK,
                        net.minecraft.world.level.block.Blocks.EMERALD_BLOCK
                    };
                    for (int i = 0; i < blocks.length; i++) {
                        var at = new net.minecraft.core.BlockPos(game.player.getBlockX() + 2 + i, 65, game.player.getBlockZ() + 2);
                        if (!game.level.getBlockState(at).is(blocks[i])) {
                            if (r.scenario.startsWith("chunks-disk")) client.fail("persisted_chunk_pattern_missing");
                            return;
                        }
                    }
                }
                client.pass("chunk_target_stable");
            }
        }
    }

    @Override public boolean prepare(Minecraft game) {
        if (r.terrainTick < 0) return false;
        double expected = r.peer.equals("alice") ? -4095.5 : 4096.5;
        if (Math.abs(game.player.getX() - expected) > 1 || Math.abs(game.player.getY() - 65) > 1
                || Math.abs(game.player.getZ() - expected) > 1) {
            var velocity = game.player.getDeltaMovement();
            client.event("stream_position_changed", "x", game.player.getX(), "y", game.player.getY(), "z", game.player.getZ(),
                "velocity_x", velocity.x, "velocity_y", velocity.y, "velocity_z", velocity.z,
                "flying", game.player.getAbilities().flying, "on_ground", game.player.onGround());
            client.fail("independent_stream_position_changed");
            return false;
        }
        if (r.scenario.equals("chunks-isolation") && r.peer.equals("bob")) {
            var channel = ((ClientConnectionAccessor) game.getConnection().getConnection()).lightningRod$channel();
            if (!readsPaused) {
                channel.config().setAutoRead(false);
                readsPaused = true;
                client.event("slow_reader_paused");
            }
            if (!readsResumed && Files.exists(r.artifacts.resolve("alice.result"))) {
                channel.config().setAutoRead(true);
                readsResumed = true;
                client.restartStream();
                targetTick = -1;
                client.event("slow_reader_resumed");
            }
            if (!readsResumed) return false;
        }
        return true;
    }
}
