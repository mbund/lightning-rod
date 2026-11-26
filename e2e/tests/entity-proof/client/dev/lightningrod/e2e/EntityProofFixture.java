package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;

/**
 * Stands clear of what the server fires or drops, tracing it, until both waves have long come to
 * rest. The runner then holds the trace to the server's.
 */
final class EntityProofFixture extends Fixture {
    private boolean placed;
    private long start;

    EntityProofFixture(Recorder r) { super(r); }

    @Override boolean traceEntities() { return true; }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missingChunks(game, 1) != 0) return;
        if (!placed) {
            if (r.scenario.startsWith("entity-proof-ocean")) {
                // At the pool's north edge, looking down into it: what the server hides it cannot prove.
                game.player.setPos(22.5, 65, 18.5);
                game.player.setYRot(0);
                game.player.setXRot(50);
            } else {
                // South of the drops and the arrows' path.
                game.player.setPos(8.5, 65, -6.5);
            }
            placed = true;
            start = r.tick;
            return;
        }
        // Stones that reach the ocean's floor rise twenty blocks at about a fortieth of one a tick.
        long wait = r.scenario.startsWith("entity-proof-ocean") ? 1400 : 600;
        if (r.tick - start > wait) client.pass("entity-proof");
    }
}
