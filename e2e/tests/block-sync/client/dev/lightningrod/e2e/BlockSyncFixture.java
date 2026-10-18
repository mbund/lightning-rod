package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;

final class BlockSyncFixture extends Fixture {
    private enum Phase { ADDED, REMOVE, REMOVED, BURST, SINGLE, SINGLE_OBSERVED, CHECK, CHECKED, CLOCK, CLOCK_CHECK, COMPLETE }
    private Phase phase = Phase.ADDED;
    private boolean blocksRequested;
    private int blocksInitialChunkPackets;
    private boolean readsResumed;
    private boolean burstRequested;

    BlockSyncFixture(Recorder r) { super(r); }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick >= 0 && r.tick - r.terrainTick > 800) {
            client.fail("block_synchronization_timeout_stage_" + phase);
            return;
        }
        if (r.terrainTick < 0 || missingChunks(game, 2) != 0) return;
        if (!client.marked(r.peer + ".blocks-ready")) {
            game.player.setPos(r.peer.equals("alice") ? 0.5 : 5.5, 65, 4.5);
            game.player.setYRot(r.peer.equals("alice") ? -162 : 142);
            game.player.setXRot(20);
            client.mark(r.peer + ".blocks-ready");
        }
        for (String other : r.expectedPeers) if (!client.marked(other + ".blocks-ready")) return;
        if (!blocksRequested && r.peer.equals("alice")) {
            blocksRequested = true;
            client.send("blocks_add");
        }
        var first = new BlockPos(2, 64, 0);
        var second = new BlockPos(2, 64, 1);
        var negative = new BlockPos(-1, 64, -1);
        if (phase == Phase.ADDED && game.level.getBlockState(first).is(net.minecraft.world.level.block.Blocks.STONE)
            && game.level.getBlockState(second).is(net.minecraft.world.level.block.Blocks.DIRT)
            && game.level.getBlockState(negative).is(net.minecraft.world.level.block.Blocks.STONE)) {
            if (!game.levelRenderer.hasRenderedAllSections()) return;
            if (!client.screenshot("blocks_added").done()) return;
            client.mark(r.peer + ".blocks-added");
            phase = Phase.REMOVE;
        }
        if (phase == Phase.REMOVE) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".blocks-added")) return;
            phase = Phase.REMOVED;
            if (r.peer.equals("alice")) client.send("blocks_remove");
        }
        if (phase == Phase.REMOVED && game.level.getBlockState(first).isAir()
            && game.level.getBlockState(second).isAir() && game.level.getBlockState(negative).isAir()
            && missingChunks(game, r.minimumRadius) == 0) {
            blocksInitialChunkPackets = r.observedChunkPackets;
            client.mark(r.peer + ".blocks-burst-ready");
            for (String other : r.expectedPeers) if (!client.marked(other + ".blocks-burst-ready")) return;
            phase = Phase.BURST;
            if (r.peer.equals("bob")) {
                ((ClientConnectionAccessor) game.getConnection().getConnection()).lightningRod$channel().config().setAutoRead(false);
                client.mark("bob.blocks-paused");
                client.event("block_reader_paused");
            }
        }
        if (phase == Phase.BURST) {
            if (r.peer.equals("alice") && !burstRequested) {
                if (!client.marked("bob.blocks-paused")) return;
                client.send("blocks_burst");
                burstRequested = true;
            }
            if (r.peer.equals("bob") && !readsResumed) {
                // The paused socket cannot carry Alice's completion signal.
                if (!java.nio.file.Files.exists(r.artifacts.resolve("alice.blocks-burst"))) return;
                ((ClientConnectionAccessor) game.getConnection().getConnection()).lightningRod$channel().config().setAutoRead(true);
                readsResumed = true;
                client.event("block_reader_resumed");
            }
            for (int section = 0; section < 125; section++) {
                var pos = new BlockPos((section % 5 - 2) * 16 + 15, (9 + section / 25) * 16 + 15, (section / 5 % 5 - 2) * 16 + 15);
                if (!game.level.getBlockState(pos).is(net.minecraft.world.level.block.Blocks.DIRT)) return;
            }
            var pos = new BlockPos.MutableBlockPos();
            for (int section = 0; section < 125; section++) for (int local = 0; local < 4096; local++) {
                pos.set((section % 5 - 2) * 16 + (local & 15), (9 + section / 25) * 16 + (local >> 8), (section / 5 % 5 - 2) * 16 + ((local >> 4) & 15));
                var expected = section == 0 && local == 0 ? net.minecraft.world.level.block.Blocks.GOLD_BLOCK
                    : local % 2 == 0 ? net.minecraft.world.level.block.Blocks.STONE : net.minecraft.world.level.block.Blocks.DIRT;
                if (!game.level.getBlockState(pos).is(expected)) {
                    client.fail("incorrect_burst_block_" + pos);
                    return;
                }
            }
            client.mark(r.peer + ".blocks-burst");
            if (r.peer.equals("alice")) r.marker("alice.blocks-burst");
            phase = Phase.SINGLE;
        }
        if (phase == Phase.SINGLE) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".blocks-burst")) return;
            phase = Phase.SINGLE_OBSERVED;
            if (r.peer.equals("alice")) client.send("blocks_single");
        }
        if (phase == Phase.SINGLE_OBSERVED && game.level.getBlockState(new BlockPos(33, 208, 33)).is(net.minecraft.world.level.block.Blocks.GOLD_BLOCK)) {
            client.mark(r.peer + ".blocks-single");
            phase = Phase.CHECK;
        }
        if (phase == Phase.CHECK) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".blocks-single")) return;
            client.send("blocks_check");
            phase = Phase.CHECKED;
        }
        if (phase == Phase.CHECKED && client.received("Block synchronization verified")) {
            phase = Phase.CLOCK;
            if (r.peer.equals("alice")) client.send("blocks_clock");
        }
        if (phase == Phase.CLOCK && client.received("Block clock completed")) {
            for (int index = 0; index < 64; index++)
                if (!game.level.getBlockState(new BlockPos(32 + index % 16, 209, 32 + index / 16)).is(net.minecraft.world.level.block.Blocks.GOLD_BLOCK)) return;
            client.mark(r.peer + ".blocks-clock");
            phase = Phase.CLOCK_CHECK;
        }
        if (phase == Phase.CLOCK_CHECK) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".blocks-clock")) return;
            client.send("blocks_clock_check");
            phase = Phase.COMPLETE;
        }
        if (phase == Phase.COMPLETE && client.received("Block clock verified")) {
            if (r.observedChunkPackets != blocksInitialChunkPackets) client.fail("block_changes_resent_chunks");
            else client.pass("burst_512000_blocks_and_64_tick_clock_verified");
        }

    }
}
