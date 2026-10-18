package dev.lightningrod.e2e;

import java.util.UUID;
import net.minecraft.client.Minecraft;
import net.minecraft.world.BossEvent;
import dev.lightningrod.e2e.mixin.BossBarHudAccessor;

final class BossbarsFixture extends Fixture {
    private static final long TIMEOUT_NS = 30_000_000_000L;
    private enum Phase { WAITING, CREATED, UPDATED, ALICE, BOB, REMOVED, RECREATED, RELOADED }
    private Phase phase = Phase.WAITING;
    private long startedNs = -1;
    private int readyJoin;
    private boolean acknowledged;
    private UUID id;

    BossbarsFixture(Recorder r) { super(r); }

    @Override boolean prepare(Minecraft game) {
        game.getTutorial().setStep(net.minecraft.client.tutorial.TutorialSteps.NONE);
        return true;
    }

    @Override void message(String text) {
        switch (text) {
            case "created", "updated", "alice", "bob", "removed", "recreated", "reloaded" -> {
                phase = Phase.valueOf(text.toUpperCase(java.util.Locale.ROOT));
                acknowledged = false;
            }
            default -> throw new IllegalArgumentException("unexpected bossbar phase: " + text);
        }
    }

    public void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || game.player == null || GuiApi.screen(game) != null) return;
        if (startedNs < 0) startedNs = System.nanoTime();
        if (System.nanoTime() - startedNs > TIMEOUT_NS) { client.fail("bossbar_timeout_" + phase); return; }
        var bars = ((BossBarHudAccessor) GuiApi.bossBars(game)).lightningRod$bossBars();
        if (readyJoin != r.joins) {
            readyJoin = r.joins;
            client.send("ready");
            return;
        }
        if (acknowledged || phase == Phase.WAITING) return;
        boolean privatePhase = phase == Phase.ALICE || phase == Phase.BOB;
        boolean absent = phase == Phase.REMOVED || (privatePhase && !phase.name().equalsIgnoreCase(r.peer));
        if (bars.size() != (absent ? 0 : 1)) return;
        if (!absent) {
            var entry = bars.entrySet().iterator().next();
            if (id == null) id = entry.getKey();
            if (!id.equals(entry.getKey())) { client.fail("bossbar_id_changed"); return; }
            var bar = entry.getValue();
            String title = switch (phase) {
                case CREATED -> "Fixture created";
                case UPDATED -> "Fixture updated";
                case ALICE, BOB -> "Private " + r.peer;
                case RECREATED -> "Fixture recreated";
                case RELOADED -> "Fixture restored";
                default -> throw new IllegalStateException(phase.name());
            };
            float progress = phase == Phase.CREATED ? 0.25f : privatePhase ? 0.5f : 0.75f;
            BossEvent.BossBarColor color = phase == Phase.CREATED ? BossEvent.BossBarColor.GREEN
                : privatePhase ? BossEvent.BossBarColor.BLUE : BossEvent.BossBarColor.PURPLE;
            BossEvent.BossBarOverlay overlay = phase == Phase.CREATED ? BossEvent.BossBarOverlay.PROGRESS
                : privatePhase ? BossEvent.BossBarOverlay.NOTCHED_6 : BossEvent.BossBarOverlay.NOTCHED_10;
            if (!bar.getName().getString().equals(title) || !close(bar.getProgress(), progress, 0.01)
                    || bar.getColor() != color || bar.getOverlay() != overlay) return;
        }
        if (phase == Phase.RELOADED && (r.joins != 2 || game.level.players().size() != 2)) return;
        if (!client.screenshot("bossbars_" + phase.name().toLowerCase(java.util.Locale.ROOT)).done()) return;
        acknowledged = true;
        if (phase == Phase.RELOADED) {
            client.pass("bossbar_create_update_audience_remove_recreate_reload_verified");
        } else {
            client.send("observed");
        }
    }
}
