package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.phys.Vec3;

final class OcclusionMountainFixture extends Fixture {
    private static final int DISTANCE = 32;
    private static final int CACHE_DISTANCE = DISTANCE + 3;
    private static final int COLUMNS = (CACHE_DISTANCE * 2 + 1) * (CACHE_DISTANCE * 2 + 1);
    private static final double RADIUS = 224;
    private static final double STEP = 4;
    private static final int FLIGHT_TICKS = (int) Math.ceil(2 * Math.PI * RADIUS / STEP);
    private final BlockPos.MutableBlockPos sample = new BlockPos.MutableBlockPos();
    private int flightTick;
    private long frames;
    private long rays;
    private long cells;
    private boolean flying;
    private boolean failed;
    private long started;
    private long finished;
    private long loadingProgress;
    private int loadingColumns;
    private int viewX;
    private int viewZ;

    OcclusionMountainFixture(Recorder recorder) { super(recorder); }
    @Override boolean encrypted() { return true; }
    @Override int renderDistance() { return DISTANCE; }
    @Override boolean prepare(Minecraft game) { return true; }
    @Override void viewCenter(int x, int z) { viewX = x; viewZ = z; }
    @Override void connected(Minecraft game) {
        if (!game.player.getAbilities().flying) {
            game.player.getAbilities().flying = true;
            game.player.onUpdateAbilities();
        }
        if (!flying) {
            game.player.setPos(-RADIUS, 112, 0);
            game.player.setDeltaMovement(Vec3.ZERO);
        }
    }

    private static int height(int x, int z) { return 64 + Math.max(0, 192 - (Math.abs(x) + Math.abs(z)) * 3 / 2); }

    private static Block reference(int x, int y, int z) {
        int top = height(x, z);
        boolean cave = y >= 20 && y < 28 && Math.floorMod(x, 64) >= 8 && Math.floorMod(x, 64) < 16
            && Math.floorMod(z, 64) >= 8 && Math.floorMod(z, 64) < 16;
        return y > top || cave ? Blocks.AIR : y == top ? top >= 192 ? Blocks.SNOW_BLOCK : Blocks.GRASS_BLOCK : Blocks.STONE;
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || failed) return;
        if (!flying) {
            long now = System.nanoTime();
            if (loadingProgress == 0 || loaded != loadingColumns) {
                loadingProgress = now;
                loadingColumns = loaded;
            }
            if (now - loadingProgress > 60_000_000_000L) {
                fail("initial_streaming_stalled", game.player.getBlockX(), game.player.getBlockY(), game.player.getBlockZ());
                return;
            }
            if (loaded < COLUMNS || missing != 0 || missingChunks(game, CACHE_DISTANCE) != 0) return;
            for (int z = -32; z <= 32; z += 16) for (int x = 48; x <= 96; x += 16) {
                sample.set(x, height(x, z), z);
                if (!game.level.getBlockState(sample).is(reference(x, height(x, z), z))) {
                    fail("exterior_region_missing_mountain_backside", x, height(x, z), z);
                    return;
                }
            }
            game.player.setYRot(-90);
            game.player.setXRot(-10);
            if (!client.screenshot("exterior_region_loaded").done()) return;
            game.player.getAbilities().flying = true;
            game.player.onUpdateAbilities();
            started = System.nanoTime();
            flying = true;
        }
        if (flightTick == FLIGHT_TICKS) {
            if (!client.screenshot("mountain_flight_complete").done()) return;
            client.event("mountain_flight", "speed_blocks_s", STEP * 20, "frames", frames, "rays", rays, "cells", cells,
                "flight_elapsed_ms", (finished - started) / 1_000_000L, "capture_elapsed_ms", (System.nanoTime() - finished) / 1_000_000L);
            client.pass("mountain_flight_never_exposes_placeholders_or_sealed_caves");
            return;
        }
        double angle = Math.PI + ++flightTick * STEP / RADIUS;
        game.player.setPos(Math.cos(angle) * RADIUS, 112, Math.sin(angle) * RADIUS);
        game.player.setDeltaMovement(Vec3.ZERO);
        game.player.setYRot((float) Math.toDegrees(Math.atan2(game.player.getX(), -game.player.getZ())));
        game.player.setXRot(-10);
        if (flightTick == FLIGHT_TICKS) finished = System.nanoTime();
        if (flightTick == FLIGHT_TICKS / 4) client.snapshot("north_side");
        if (flightTick == FLIGHT_TICKS / 2) client.snapshot("backside");
        if (flightTick == FLIGHT_TICKS * 3 / 4) client.snapshot("south_side");
    }

    @Override void frame(Minecraft game) {
        if (!flying || failed || game.player == null || game.level == null) return;
        frames++;
        int missingHorizon = missingHorizonChunks(game);
        if (missingHorizon != 0) {
            StringBuilder gaps = new StringBuilder();
            int nearest = Integer.MAX_VALUE;
            int cx = game.player.getBlockX() >> 4, cz = game.player.getBlockZ() >> 4;
            for (int dz = -DISTANCE; dz <= DISTANCE; dz++) for (int dx = -DISTANCE; dx <= DISTANCE; dx++) {
                if (game.level.getChunkSource().getChunk(cx + dx, cz + dz, ChunkStatus.FULL, false) != null) continue;
                nearest = Math.min(nearest, dx * dx + dz * dz);
                if (gaps.length() < 2048) gaps.append(cx + dx).append(',').append(cz + dz).append(' ');
            }
            client.event("mountain_horizon_gap", "view_x", viewX, "view_z", viewZ,
                "player_chunk_x", game.player.getBlockX() >> 4, "player_chunk_z", game.player.getBlockZ() >> 4,
                "loaded", game.level.getChunkSource().getLoadedChunksCount(), "missing", missingChunks(game, DISTANCE),
                "missing_horizon", missingHorizon, "nearest_gap_chunks", Math.sqrt(nearest), "columns", gaps.toString());
            fail("rendered_flight_horizon_missing_columns", game.player.getBlockX(), game.player.getBlockY(), game.player.getBlockZ());
            return;
        }
        double x = game.player.getX(), y = game.player.getY() + 1.62, z = game.player.getZ();
        for (int tz = -128; tz <= 128 && !failed; tz += 16) for (int tx = -128; tx <= 128 && !failed; tx += 16)
            ray(game, x, y, z, tx + 0.5, height(tx, tz) + 0.5, tz + 0.5);
        int minX = ((game.player.getBlockX() >> 4) - DISTANCE) * 16;
        int minZ = ((game.player.getBlockZ() >> 4) - DISTANCE) * 16;
        int maxX = minX + (DISTANCE * 2 + 1) * 16;
        int maxZ = minZ + (DISTANCE * 2 + 1) * 16;
        for (int tz = Math.floorDiv(minZ, 64) * 64; tz < maxZ && !failed; tz += 64)
            for (int tx = Math.floorDiv(minX, 64) * 64; tx < maxX && !failed; tx += 64) {
            if (tx + 12 < minX || tx + 12 >= maxX || tz + 12 < minZ || tz + 12 >= maxZ) continue;
            sample.set(tx + 12, 24, tz + 12);
            if (!game.level.getBlockState(sample).isAir()) fail("sealed_underground_cave_disclosed", sample.getX(), sample.getY(), sample.getZ());
        }
    }

    private static int missingHorizonChunks(Minecraft game) {
        int cx = game.player.getBlockX() >> 4, cz = game.player.getBlockZ() >> 4;
        double px = game.player.getX(), pz = game.player.getZ();
        int missing = 0;
        for (int z = cz - DISTANCE; z <= cz + DISTANCE; z++) for (int x = cx - DISTANCE; x <= cx + DISTANCE; x++) {
            double dx = Math.max(x * 16 - px, Math.max(0, px - (x + 1) * 16));
            double dz = Math.max(z * 16 - pz, Math.max(0, pz - (z + 1) * 16));
            if (dx * dx + dz * dz > DISTANCE * DISTANCE * 256) continue;
            if (game.level.getChunkSource().getChunk(x, z, ChunkStatus.FULL, false) == null) missing++;
        }
        return missing;
    }

    private void ray(Minecraft game, double ox, double oy, double oz, double tx, double ty, double tz) {
        rays++;
        double dx = tx - ox, dy = ty - oy, dz = tz - oz;
        int x = (int) Math.floor(ox), y = (int) Math.floor(oy), z = (int) Math.floor(oz);
        int sx = dx > 0 ? 1 : -1, sy = dy > 0 ? 1 : -1, sz = dz > 0 ? 1 : -1;
        double ax = Math.abs(1 / dx), ay = Math.abs(1 / dy), az = Math.abs(1 / dz);
        double nx = (dx > 0 ? x + 1 - ox : ox - x) * ax;
        double ny = (dy > 0 ? y + 1 - oy : oy - y) * ay;
        double nz = (dz > 0 ? z + 1 - oz : oz - z) * az;
        for (int steps = 0; steps < 2048; steps++) {
            cells++;
            Block expected = reference(x, y, z);
            sample.set(x, y, z);
            if (!game.level.getBlockState(sample).is(expected)) {
                client.event("mountain_block_mismatch", "expected", expected.toString(), "actual", game.level.getBlockState(sample).toString(),
                    "eye_x", ox, "eye_y", oy, "eye_z", oz, "target_x", tx, "target_y", ty, "target_z", tz);
                fail("visible_world_differs_from_reference", x, y, z);
                return;
            }
            if (expected != Blocks.AIR) return;
            double next = Math.min(nx, Math.min(ny, nz));
            if (next > 1) return;
            if (nx == next) { x += sx; nx += ax; }
            if (ny == next) { y += sy; ny += ay; }
            if (nz == next) { z += sz; nz += az; }
        }
        fail("visibility_ray_did_not_terminate", x, y, z);
    }

    private void fail(String reason, int x, int y, int z) {
        failed = true;
        client.event("mountain_visibility_failure", "reason", reason, "x", x, "y", y, "z", z, "flight_tick", flightTick, "frames", frames);
        client.fail(reason);
    }
}
