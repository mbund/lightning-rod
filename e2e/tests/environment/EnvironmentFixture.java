package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;
import net.minecraft.network.protocol.game.ServerboundMovePlayerPacket;

final class EnvironmentFixture extends Fixture {
    private int stage;
    private long started = -1;
    private long firstDay;
    private long firstAge;
    private long stable = -1;

    EnvironmentFixture(Recorder r) { super(r); }

    @Override void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0 || client.level == null || client.player == null || GuiApi.screen(client) != null) return;
        if (started < 0) {
            started = r.tick;
            firstDay = GameApi.dayTime(client);
            firstAge = client.level.getGameTime();
            double x = r.peer.equals("alice") ? -2.5 : 2.5;
            client.player.setPos(x, 65, 0.5);
            client.player.setYRot(0);
            client.player.setXRot(0);
            client.getConnection().send(new ServerboundMovePlayerPacket.PosRot(x, 65, 0.5, 0, 0, true, false));
        }
        if (r.tick - started > 1600) { r.fail(client, "environment_timeout_" + stage); return; }
        long day = GameApi.dayTime(client);
        float rain = client.level.getRainLevel(1);
        float thunder = client.level.getThunderLevel(1);
        boolean alice = r.peer.equals("alice");
        boolean overworld = GameApi.dimension(client).equals("minecraft:overworld");
        if (r.tick % 100 == 0) r.event("environment_progress", "stage", stage, "day", day,
            "age", client.level.getGameTime(), "rain", rain, "thunder", thunder, "dimension", GameApi.dimension(client));

        boolean ready = switch (stage) {
            case 0 -> r.tick - started >= 40 && day > firstDay && client.level.getGameTime() > firstAge &&
                rain == 0 && thunder == 0 && client.level.players().size() == 2;
            case 1 -> day == 6000 && rain == 1 && thunder == 1;
            case 2 -> r.joins == 2 && day == 6000 && rain == 1 && thunder == 1 && client.level.players().size() == 2;
            case 3 -> day == 6000 && (alice ? overworld && rain == 1 && thunder == 1 :
                GameApi.dimension(client).equals("minecraft:the_nether") && rain == 0 && thunder == 0);
            case 4 -> overworld && day == 6000 && rain == 1 && thunder == 1 && client.level.players().size() == 2;
            case 5 -> day == 18000 && rain == 0 && thunder == 0;
            case 6 -> day == 18000 && rain == 1 && thunder == 1;
            case 7 -> day > 0 && day < 2000 && rain == 0 && thunder == 0 && overworld;
            default -> false;
        };
        String marker = "environment-" + stage;
        if (!Files.exists(r.artifacts.resolve(r.peer + "." + marker))) {
            if (!ready || r.missingChunks(client, 1) != 0) { stable = -1; return; }
            if (stable < 0) {
                stable = r.tick;
                firstAge = client.level.getGameTime();
                return;
            }
            if (r.tick - stable < 30 || !client.levelRenderer.hasRenderedAllSections()) return;
            if (client.level.getGameTime() <= firstAge) { r.fail(client, "game_time_did_not_advance_" + stage); return; }
            String[] labels = {"daylight", "thunder", "reload", "nether", "return", "clear_night", "natural_rain", "resumed_daylight"};
            r.screenshot(client, labels[stage]);
            r.event("environment_verified", "stage", stage, "day", day, "rain", rain, "thunder", thunder);
            r.marker(r.peer + "." + marker);
        }
        for (String peer : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(peer + "." + marker))) return;
        if (stage == 7) { r.pass(client, "time_weather_reload_and_world_transfer_verified"); return; }
        String command = switch (stage) {
            case 0 -> alice ? "environment freeze" : null;
            case 1 -> alice ? "environment reload" : null;
            case 2 -> alice ? null : "environment nether";
            case 3 -> alice ? null : "environment overworld";
            case 4 -> alice ? "environment clear" : null;
            case 5 -> alice ? "environment expiry" : null;
            case 6 -> alice ? "environment resume" : null;
            default -> null;
        };
        if (command != null) client.getConnection().sendCommand(command);
        stage++;
        stable = -1;
    }
}
