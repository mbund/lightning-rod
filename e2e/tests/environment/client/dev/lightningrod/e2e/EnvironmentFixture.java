package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.network.protocol.game.ServerboundMovePlayerPacket;

final class EnvironmentFixture extends Fixture {
    private enum Phase { DAYLIGHT, THUNDER, RELOAD, NETHER, RETURN, CLEAR_NIGHT, NATURAL_RAIN, RESUMED_DAYLIGHT }
    private Phase phase = Phase.DAYLIGHT;
    private long started = -1;
    private long firstDay;
    private long firstAge;
    private long stable = -1;

    EnvironmentFixture(Recorder r) { super(r); }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || game.level == null || game.player == null || GuiApi.screen(game) != null) return;
        if (started < 0) {
            started = r.tick;
            firstDay = GameApi.dayTime(game);
            firstAge = game.level.getGameTime();
            double x = r.peer.equals("alice") ? -2.5 : 2.5;
            game.player.setPos(x, 65, 0.5);
            game.player.setYRot(0);
            game.player.setXRot(0);
            game.getConnection().send(new ServerboundMovePlayerPacket.PosRot(x, 65, 0.5, 0, 0, true, false));
        }
        if (r.tick - started > 1600) { client.fail("environment_timeout_" + phase); return; }
        long day = GameApi.dayTime(game);
        float rain = game.level.getRainLevel(1);
        float thunder = game.level.getThunderLevel(1);
        boolean alice = r.peer.equals("alice");
        boolean overworld = GameApi.dimension(game).equals("minecraft:overworld");
        if (r.tick % 100 == 0) client.event("environment_progress", "phase", phase, "day", day,
            "age", game.level.getGameTime(), "rain", rain, "thunder", thunder, "dimension", GameApi.dimension(game));

        boolean ready = switch (phase) {
            case DAYLIGHT -> day > firstDay && game.level.getGameTime() > firstAge &&
                rain == 0 && thunder == 0 && game.level.players().size() == 2;
            case THUNDER -> day == 6000 && rain == 1 && thunder == 1;
            case RELOAD -> r.joins == 2 && day == 6000 && rain == 1 && thunder == 1 && game.level.players().size() == 2;
            case NETHER -> day == 6000 && (alice ? overworld && rain == 1 && thunder == 1 :
                GameApi.dimension(game).equals("minecraft:the_nether") && rain == 0 && thunder == 0);
            case RETURN -> overworld && day == 6000 && rain == 1 && thunder == 1 && game.level.players().size() == 2;
            case CLEAR_NIGHT -> day == 18000 && rain == 0 && thunder == 0;
            case NATURAL_RAIN -> day == 18000 && rain == 1 && thunder == 1;
            case RESUMED_DAYLIGHT -> day > 0 && day < 2000 && rain == 0 && thunder == 0 && overworld;
            default -> false;
        };
        String marker = "environment-" + phase;
        if (!client.marked(r.peer + "." + marker)) {
            if (!ready || missingChunks(game, 1) != 0) { stable = -1; return; }
            if (stable < 0) {
                stable = r.tick;
                firstAge = game.level.getGameTime();
                return;
            }
            if (game.level.getGameTime() <= firstAge) return;
            if (!client.screenshot(phase.name().toLowerCase(java.util.Locale.ROOT)).done()) return;
            client.event("environment_verified", "phase", phase, "day", day, "rain", rain, "thunder", thunder);
            client.mark(r.peer + "." + marker);
        }
        for (String peer : r.expectedPeers) if (!client.marked(peer + "." + marker)) return;
        if (phase == Phase.RESUMED_DAYLIGHT) { client.pass("time_weather_reload_and_world_transfer_verified"); return; }
        String command = switch (phase) {
            case DAYLIGHT -> alice ? "environment freeze" : null;
            case THUNDER -> alice ? "environment reload" : null;
            case RELOAD -> alice ? null : "environment nether";
            case NETHER -> alice ? null : "environment overworld";
            case RETURN -> alice ? "environment clear" : null;
            case CLEAR_NIGHT -> alice ? "environment expiry" : null;
            case NATURAL_RAIN -> alice ? "environment resume" : null;
            default -> null;
        };
        if (command != null) client.send(command);
        phase = switch (phase) {
            case DAYLIGHT -> Phase.THUNDER;
            case THUNDER -> Phase.RELOAD;
            case RELOAD -> Phase.NETHER;
            case NETHER -> Phase.RETURN;
            case RETURN -> Phase.CLEAR_NIGHT;
            case CLEAR_NIGHT -> Phase.NATURAL_RAIN;
            case NATURAL_RAIN -> Phase.RESUMED_DAYLIGHT;
            case RESUMED_DAYLIGHT -> throw new IllegalStateException("environment already complete");
        };
        stable = -1;
    }
}
