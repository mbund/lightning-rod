package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;

/// Alice takes off, and the server reloads. Its new login packet resets what her client knows of
/// her abilities, so she flies afterwards only if the server kept that she was flying.
final class FlightFixture extends Fixture {
    private static final String RELOAD = "player_reload";
    private int flyingTicks;
    private boolean armed;
    private boolean reloadRequested;
    private long rejoinedTick = -1;

    FlightFixture(Recorder r) { super(r); }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (loaded < 9 || game.player == null || game.getConnection() == null) return;
        var abilities = game.player.getAbilities();
        if (r.joins == 1) {
            if (!abilities.mayfly) return;
            if (!abilities.flying) {
                abilities.flying = true;
                game.player.onUpdateAbilities();
                return;
            }
            // Long enough for the server to hear it and a checkpoint to come.
            if (++flyingTicks < 20) return;
            if (!armed) {
                r.marker(r.peer + ".reload-armed-" + RELOAD);
                armed = true;
            }
            if (!reloadRequested && Files.exists(r.artifacts.resolve("reload-request-" + RELOAD))) {
                game.getConnection().sendCommand("reload");
                reloadRequested = true;
            }
            return;
        }
        if (r.joins != 2) return;
        if (rejoinedTick < 0) rejoinedTick = r.tick;
        if (abilities.flying) {
            client.pass("flight_kept_across_reload");
            return;
        }
        if (r.tick - rejoinedTick > 100) client.fail("flight_lost_across_reload");
    }
}
