package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.block.Blocks;

final class OcclusionTransitionFixture extends Fixture {
    private static final int DISTANCE = 32;
    private static final int COLUMNS = (DISTANCE * 2 + 1) * (DISTANCE * 2 + 1);
    private static final int[] MARKER_COLUMNS = {2, 4, 8, 16, DISTANCE};
    private static final int[] MARKER_HEIGHTS = {80, 112, 144};
    private static final BlockPos RETAINED_LIGHT = new BlockPos(20, 17, 20);
    private static final BlockPos LAMP = RETAINED_LIGHT.below();
    private static final int BLOCK_LIGHT = 14;
    private static final int[][] HORIZON = {
        {-DISTANCE, -DISTANCE}, {0, -DISTANCE}, {DISTANCE, -DISTANCE},
        {-DISTANCE, 0}, {DISTANCE, 0},
        {-DISTANCE, DISTANCE}, {0, DISTANCE}, {DISTANCE, DISTANCE}
    };
    private long started;
    private int initialPackets;
    private long dataReady;
    private long previousFrame;
    private long maximumFrameGap;
    private boolean ascending;
    private boolean flying;
    private enum Lamp { INITIAL, EXTINGUISHING, RESTORING, RESTORED }
    private Lamp lamp = Lamp.INITIAL;
    private final boolean[] revealed = new boolean[HORIZON.length];
    private final boolean[] markers = new boolean[MARKER_COLUMNS.length];

    OcclusionTransitionFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }
    @Override int renderDistance() { return DISTANCE; }
    @Override boolean prepare(Minecraft game) { return true; }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || r.terrainTick < 0) return;
        if (loaded < COLUMNS || missing != 0) return;
        if (started == 0) started = System.nanoTime();
        if (!ascending) {
            if (!close(game.player.getY(), 17, 0.1)) { client.fail("sealed_cave_position_incorrect"); return; }
            if (lamp == Lamp.INITIAL) {
                if (game.level.getBrightness(LightLayer.BLOCK, RETAINED_LIGHT) != BLOCK_LIGHT) { client.fail("initial_block_light_incorrect"); return; }
                client.send("lamp_off");
                lamp = Lamp.EXTINGUISHING;
                return;
            }
            if (lamp == Lamp.EXTINGUISHING) {
                if (!game.level.getBlockState(LAMP).is(Blocks.STONE)
                        || game.level.getBrightness(LightLayer.BLOCK, RETAINED_LIGHT) != 0) return;
                client.send("lamp_on");
                lamp = Lamp.RESTORING;
                return;
            }
            if (lamp == Lamp.RESTORING) {
                if (!game.level.getBlockState(LAMP).is(Blocks.GLOWSTONE)
                        || game.level.getBrightness(LightLayer.BLOCK, RETAINED_LIGHT) != BLOCK_LIGHT) return;
                lamp = Lamp.RESTORED;
            }
            for (var offset : HORIZON) {
                if (!game.level.getBlockState(at(offset, 64)).is(Blocks.AIR)
                        || !game.level.getBlockState(at(offset, 96)).is(Blocks.AIR)) { client.fail("sealed_cave_disclosed_horizon"); return; }
            }
            for (int distance : MARKER_COLUMNS) for (int height : MARKER_HEIGHTS) {
                if (!game.level.getBlockState(at(new int[]{distance, 0}, height)).is(Blocks.AIR)) {
                    client.fail("sealed_cave_disclosed_elevated_terrain");
                    return;
                }
            }
            if (!client.screenshot("sealed_horizon").done()) return;
            ascending = true;
            initialPackets = r.observedChunkPackets;
            started = System.nanoTime();
            client.send("ascend");
            return;
        }
        if (game.player.getY() < 65) return;
        if (!flying) {
            game.player.getAbilities().flying = true;
            game.player.onUpdateAbilities();
            flying = true;
        }
        game.options.keyJump.setDown(game.player.getY() < MARKER_HEIGHTS[MARKER_HEIGHTS.length - 1] + 16);
        if (game.player.getY() < 66) return;
        boolean complete = true;
        for (int i = 0; i < HORIZON.length; i++) {
            boolean grass = game.level.getBlockState(at(HORIZON[i], 64)).is(Blocks.GRASS_BLOCK);
            if (revealed[i] && !grass) { client.fail("previously_revealed_horizon_reconcealed"); return; }
            revealed[i] |= grass;
            complete &= grass && game.level.getBlockState(at(HORIZON[i], 96)).isAir();
        }
        for (boolean marker : markers) complete &= marker;
        if (!complete) return;
        if (game.level.getBrightness(LightLayer.BLOCK, RETAINED_LIGHT) != BLOCK_LIGHT) { client.fail("unchanged_light_lost_on_column_replacement"); return; }
        if (dataReady == 0) dataReady = System.nanoTime();
        if (!client.screenshot("horizon_revealed_after_ascent").done()) return;
        client.event("horizon_reveal", "elapsed_ms", (System.nanoTime() - started) / 1_000_000L, "height", game.player.getY(),
            "column_packets", r.observedChunkPackets - initialPackets, "maximum_frame_gap_ms", maximumFrameGap / 1_000_000L,
            "data_ready_ms", (dataReady - started) / 1_000_000L, "capture_ready_ms", (System.nanoTime() - dataReady) / 1_000_000L);
        game.options.keyJump.setDown(false);
        client.pass("cave_exit_reveals_complete_columns_near_first_and_retains_disclosed_terrain");
    }

    @Override void chunkData(Minecraft game, int x, int z) {
        if (!ascending || game.level == null || z != 1) return;
        for (int i = 0; i < MARKER_COLUMNS.length; i++) {
            if (x != 1 + MARKER_COLUMNS[i]) continue;
            boolean ground = game.level.getBlockState(new BlockPos(x * 16 + 8, 64, 24)).is(Blocks.GRASS_BLOCK);
            boolean any = ground;
            boolean all = ground;
            for (int height : MARKER_HEIGHTS) {
                boolean present = game.level.getBlockState(new BlockPos(x * 16 + 8, height, 24)).is(Blocks.GOLD_BLOCK);
                any |= present;
                all &= present;
            }
            if (!any) return;
            if (!all) { client.fail("column_revealed_in_vertical_fragments_" + x); return; }
            for (int previous = 0; previous < i; previous++) {
                if (!markers[previous]) { client.fail("distant_column_revealed_before_nearby_column_" + x); return; }
            }
            markers[i] = true;
            return;
        }
    }

    @Override void frame(Minecraft game) {
        if (!ascending) return;
        long now = System.nanoTime();
        if (previousFrame != 0) maximumFrameGap = Math.max(maximumFrameGap, now - previousFrame);
        previousFrame = now;
        for (var offset : HORIZON) {
            if (!game.level.getBlockState(at(offset, 303)).isAir()) {
                client.fail("artificial_ceiling_during_cave_exit");
                return;
            }
        }
    }

    private static BlockPos at(int[] offset, int y) {
        return new BlockPos((1 + offset[0]) * 16 + 8, y, (1 + offset[1]) * 16 + 8);
    }
}
