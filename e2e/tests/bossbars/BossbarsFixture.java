package dev.lightningrod.e2e;

import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;
import net.minecraft.client.MinecraftClient;
import dev.lightningrod.e2e.mixin.BossBarHudAccessor;

final class BossbarsFixture extends Fixture {
    private static final Pattern TITLE = Pattern.compile("(1|10|60)s \\| ([0-9.]+) TPS \\| ([0-9.]+) MSPT");
    private final Set<UUID> ids = new HashSet<>();
    private long started = -1;
    private boolean privateSeen;
    private boolean spike;
    private boolean recovered;
    private boolean requested;
    private long resumed = -1;

    BossbarsFixture(Recorder r) { super(r); }

    @Override boolean prepare(MinecraftClient client) {
        client.getTutorialManager().setStep(net.minecraft.client.tutorial.TutorialStep.NONE);
        return true;
    }

    public void tick(MinecraftClient client, int loaded, int missing) {
        if (r.terrainTick < 0 || client.player == null || client.currentScreen != null) return;
        if (started < 0) started = r.tick;
        if (r.tick - started > 1900) { r.fail(client, "bossbar_timeout"); return; }
        var bars = ((BossBarHudAccessor) client.inGameHud.getBossBarHud()).lightningRod$bossBars();
        int count = 0;
        double shortMspt = -1, mediumMspt = -1;
        Set<Integer> windows = new HashSet<>();
        for (var entry : bars.entrySet()) {
            var bar = entry.getValue();
            String name = bar.getName().getString();
            if (name.startsWith("Private ")) {
                if (!name.equals("Private " + r.peer)) { r.fail(client, "bossbar_audience_leak"); return; }
                privateSeen = true;
                continue;
            }
            var match = TITLE.matcher(name);
            if (!match.matches()) continue;
            int window = Integer.parseInt(match.group(1));
            double tps = Double.parseDouble(match.group(2)), mspt = Double.parseDouble(match.group(3));
            if (!windows.add(window) || !Double.isFinite(tps) || !Double.isFinite(mspt) || tps < 0 || tps > 20 || mspt < 0 || bar.getPercent() < 0 || bar.getPercent() > 1) {
                r.fail(client, "invalid_bossbar_metrics"); return;
            }
            if (window == 1) shortMspt = mspt;
            if (window == 10) mediumMspt = mspt;
            ids.add(entry.getKey());
            count++;
        }
        if (ids.size() > 3) { r.fail(client, "bossbar_ids_changed"); return; }
        if (count != 3) return;
        if (shortMspt > 5 && !spike) { spike = true; r.screenshot(client, "bossbars_load"); }
        if (spike && shortMspt < 3 && mediumMspt > shortMspt + 0.2 && !recovered) { recovered = true; r.screenshot(client, "bossbars_rolling_recovery"); }
        if (r.joins == 1 && r.tick - started >= 1300 && privateSeen && recovered && bars.size() == 3 && !requested) {
            r.screenshot(client, "bossbars_full_windows");
            if (r.peer.equals("alice")) client.getNetworkHandler().sendChatCommand("reload");
            requested = true;
        }
        if (r.joins == 2) {
            if (resumed < 0) resumed = r.tick;
            if (r.tick - resumed < 170 || bars.size() != 3 || client.world.getPlayers().size() != 2) return;
            if (!privateSeen || !recovered) { r.fail(client, "bossbar_coverage_missing"); return; }
            r.screenshot(client, "bossbars_after_reload");
            r.pass(client, "three_rolling_windows_and_bossbar_lifecycle_verified");
        }
    }
}
