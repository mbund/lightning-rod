package dev.lightningrod.e2e;

import java.io.IOException;
import java.nio.file.Files;
import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;

final class BlockSyncFixture extends Fixture {
    private int blocksStage;
    private boolean blocksRequested;
    private long blocksVisibleTick = -1;
    private int blocksInitialChunkPackets;
    private boolean readsPaused;
    private boolean readsResumed;

    BlockSyncFixture(Recorder r) { super(r); }

    @Override public void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick >= 0 && r.tick - r.terrainTick > 800) {
            r.fail(client, "block_synchronization_timeout_stage_" + blocksStage);
            return;
        }
        if (r.terrainTick < 0 || r.missingChunks(client, 2) != 0) return;
        try {
            if (!Files.exists(r.artifacts.resolve(r.peer + ".blocks-ready"))) {
                client.player.setPos(r.peer.equals("alice") ? 0.5 : 5.5, 65, 4.5);
                client.player.setYRot(r.peer.equals("alice") ? -162 : 142);
                client.player.setXRot(20);
                Files.writeString(r.artifacts.resolve(r.peer + ".blocks-ready"), "ready");
            }
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".blocks-ready"))) return;
            if (!blocksRequested && r.peer.equals("alice")) {
                blocksRequested = true;
                client.getConnection().sendCommand("blocks_add");
            }
            var first = new BlockPos(2, 64, 0);
            var second = new BlockPos(2, 64, 1);
            var negative = new BlockPos(-1, 64, -1);
            if (blocksStage == 0 && client.level.getBlockState(first).is(net.minecraft.world.level.block.Blocks.STONE)
                && client.level.getBlockState(second).is(net.minecraft.world.level.block.Blocks.DIRT)
                && client.level.getBlockState(negative).is(net.minecraft.world.level.block.Blocks.STONE)) {
                if (blocksVisibleTick < 0) blocksVisibleTick = r.tick;
                if (r.tick - blocksVisibleTick < 40) return;
                r.screenshot(client, "blocks_added");
                Files.writeString(r.artifacts.resolve(r.peer + ".blocks-added"), "added");
                blocksStage = 1;
            }
            if (blocksStage == 1) {
                for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".blocks-added"))) return;
                blocksStage = 2;
                if (r.peer.equals("alice")) client.getConnection().sendCommand("blocks_remove");
            }
            if (blocksStage == 2 && client.level.getBlockState(first).isAir()
                && client.level.getBlockState(second).isAir() && client.level.getBlockState(negative).isAir()
                && r.missingChunks(client, 32) == 0) {
                if (r.peer.equals("bob") && !readsPaused) {
                    ((ClientConnectionAccessor) client.getConnection().getConnection()).lightningRod$channel().config().setAutoRead(false);
                    readsPaused = true;
                    r.event("block_reader_paused");
                }
                blocksInitialChunkPackets = r.observedChunkPackets;
                Files.writeString(r.artifacts.resolve(r.peer + ".blocks-burst-ready"), "ready");
                for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".blocks-burst-ready"))) return;
                blocksStage = 3;
                if (r.peer.equals("alice")) client.getConnection().sendCommand("blocks_burst");
            }
            if (blocksStage == 3) {
                if (r.peer.equals("bob") && !readsResumed) {
                    if (!Files.exists(r.artifacts.resolve("alice.blocks-burst"))) return;
                    ((ClientConnectionAccessor) client.getConnection().getConnection()).lightningRod$channel().config().setAutoRead(true);
                    readsResumed = true;
                    r.event("block_reader_resumed");
                }
                for (int section = 0; section < 125; section++) {
                    var pos = new BlockPos((section % 5 - 2) * 16 + 15, (9 + section / 25) * 16 + 15, (section / 5 % 5 - 2) * 16 + 15);
                    if (!client.level.getBlockState(pos).is(net.minecraft.world.level.block.Blocks.DIRT)) return;
                }
                var pos = new BlockPos.MutableBlockPos();
                for (int section = 0; section < 125; section++) for (int local = 0; local < 4096; local++) {
                    pos.set((section % 5 - 2) * 16 + (local & 15), (9 + section / 25) * 16 + (local >> 8), (section / 5 % 5 - 2) * 16 + ((local >> 4) & 15));
                    var expected = section == 0 && local == 0 ? net.minecraft.world.level.block.Blocks.GOLD_BLOCK
                        : local % 2 == 0 ? net.minecraft.world.level.block.Blocks.STONE : net.minecraft.world.level.block.Blocks.DIRT;
                    if (!client.level.getBlockState(pos).is(expected)) {
                        r.fail(client, "incorrect_burst_block_" + pos);
                        return;
                    }
                }
                Files.writeString(r.artifacts.resolve(r.peer + ".blocks-burst"), "verified");
                blocksStage = 4;
            }
            if (blocksStage == 4) {
                for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".blocks-burst"))) return;
                blocksStage = 5;
                if (r.peer.equals("alice")) client.getConnection().sendCommand("blocks_single");
            }
            if (blocksStage == 5 && client.level.getBlockState(new BlockPos(33, 208, 33)).is(net.minecraft.world.level.block.Blocks.GOLD_BLOCK)) {
                Files.writeString(r.artifacts.resolve(r.peer + ".blocks-single"), "verified");
                blocksStage = 6;
            }
            if (blocksStage == 6) {
                for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".blocks-single"))) return;
                client.getConnection().sendCommand("blocks_check");
                blocksStage = 7;
            }
            if (blocksStage == 7 && r.receivedChat.contains("Block synchronization verified")) {
                blocksStage = 8;
                if (r.peer.equals("alice")) client.getConnection().sendCommand("blocks_clock");
            }
            if (blocksStage == 8 && r.receivedChat.contains("Block clock completed")) {
                for (int index = 0; index < 64; index++)
                    if (!client.level.getBlockState(new BlockPos(32 + index % 16, 209, 32 + index / 16)).is(net.minecraft.world.level.block.Blocks.GOLD_BLOCK)) return;
                Files.writeString(r.artifacts.resolve(r.peer + ".blocks-clock"), "verified");
                blocksStage = 9;
            }
            if (blocksStage == 9) {
                for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".blocks-clock"))) return;
                client.getConnection().sendCommand("blocks_clock_check");
                blocksStage = 10;
            }
            if (blocksStage == 10 && r.receivedChat.contains("Block clock verified")) {
                if (r.observedChunkPackets != blocksInitialChunkPackets) r.fail(client, "block_changes_resent_chunks");
                else r.pass(client, "burst_512000_blocks_and_64_tick_clock_verified");
            }
        } catch (IOException error) { throw new IllegalStateException(error); }

    }
}
