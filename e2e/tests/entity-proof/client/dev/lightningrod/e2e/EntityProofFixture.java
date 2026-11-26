package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;

/**
 * Stands clear of the arrows the server fires, tracing them, until both waves have long been
 * stuck. The runner then holds the trace to the server's.
 */
final class EntityProofFixture extends Fixture {
    private boolean placed;
    private long start;

    EntityProofFixture(Recorder r) { super(r); }

    @Override boolean traceEntities() { return true; }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missingChunks(game, 1) != 0) return;
        if (!placed) {
            // South of the drops and the arrows' path.
            game.player.setPos(8.5, 65, -6.5);
            placed = true;
            start = r.tick;
            return;
        }
        if (r.tick - start > 600) client.pass("entity-proof");
    }
}
