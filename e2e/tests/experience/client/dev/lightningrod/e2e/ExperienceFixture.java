package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.client.player.RemotePlayer;
import net.minecraft.network.protocol.game.ServerboundMovePlayerPacket;
import net.minecraft.world.entity.ExperienceOrb;

final class ExperienceFixture extends Fixture {
    private enum Phase { WAITING, SPAWNED, RESTORED_ORBS, COLLECTING, WAIT_RELOAD, COMPLETE, ARITHMETIC }
    private static final int[] POINTS = {1, 6, 93, -1, -100, 1000, 10000, -11000, 1395, 1, 1507, -2000, 0};
    private static final int[] LEVELS = {1, 5, -2, 30, -40, 14, 1, 14, 1, -31, 0};
    private Phase phase = Phase.WAITING;
    private int readyJoin;
    private long started;
    private boolean moving;
    private boolean fenced;
    private RemotePlayer oracle;
    private int arithmeticStep;
    private boolean arithmeticPending;
    private boolean arithmeticAcknowledged;

    ExperienceFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }
    @Override boolean prepare(Minecraft game) {
        game.getTutorial().setStep(net.minecraft.client.tutorial.TutorialSteps.NONE);
        return true;
    }
    @Override void message(String text) {
        if (text.startsWith("fence ")) return;
        if (text.equals("arithmetic")) { arithmeticAcknowledged = true; return; }
        phase = switch (text) {
            case "spawned" -> Phase.SPAWNED;
            case "restored_orbs" -> Phase.RESTORED_ORBS;
            case "complete" -> Phase.COMPLETE;
            default -> throw new IllegalStateException("Unexpected experience message " + text);
        };
    }
    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || r.terrainTick < 0 || missing != 0) return;
        if (started == 0) started = System.nanoTime();
        if (System.nanoTime() - started > 120_000_000_000L) { client.fail("experience_timeout_" + phase); return; }
        if (readyJoin != r.joins) { readyJoin = r.joins; client.send("ready"); return; }
        boolean alice = r.peer.equals("alice");
        if (!alice && !game.player.isSpectator()) return;
        int total = 0;
        int orbs = 0;
        for (var entity : game.level.entitiesForRendering()) if (entity instanceof ExperienceOrb orb && !orb.isRemoved()) {
            total += orb.getValue();
            orbs++;
        }
        if (phase == Phase.SPAWNED || phase == Phase.RESTORED_ORBS) {
            if (total != 100 || orbs != 4 || game.player.totalExperience != 0) return;
            if (alice && (!game.player.getMainHandItem().isEnchanted() || game.player.getMainHandItem().getDamageValue() != 2)) return;
            var delta = new net.minecraft.world.phys.Vec3(8.5, 65.3, 0.5).subtract(game.player.getEyePosition());
            game.player.setYRot((float)Math.toDegrees(Math.atan2(-delta.x, delta.z)));
            game.player.setXRot((float)-Math.toDegrees(Math.atan2(delta.y, Math.hypot(delta.x, delta.z))));
            if (!client.screenshot(phase == Phase.SPAWNED ? "experience_orbs" : "orbs_after_reload").done()) return;
            if (phase == Phase.SPAWNED) { client.send("seen"); phase = Phase.WAIT_RELOAD; }
            else { client.mark(r.peer + ".orbs-restored"); phase = Phase.COLLECTING; }
        }
        if (phase == Phase.COLLECTING) {
            for (String peer : r.expectedPeers) if (!client.marked(peer + ".orbs-restored")) return;
            if (alice && !moving) {
                game.player.setPos(8.5, 65, 0.5);
                game.getConnection().send(new ServerboundMovePlayerPacket.Pos(8.5, 65, 0.5, true, false));
                moving = true;
            }
            if (!alice) {
                if (game.player.totalExperience != 0) { client.fail("spectator_collected_experience"); return; }
                return;
            }
            if (orbs != 0 || game.player.totalExperience != 99 || game.player.experienceLevel != 7) return;
            if (!close(game.player.experienceProgress, 8.0 / 21.0, 0.00001)) { client.fail("experience_progress"); return; }
            if (game.player.getMainHandItem().getDamageValue() != 0) return;
            if (!client.screenshot("experience_collected").done()) return;
            client.send("collected");
            phase = Phase.WAIT_RELOAD;
        }
        if (phase == Phase.COMPLETE) {
            if (!fenced) { client.fence("experience-restored"); fenced = true; return; }
            if (!client.fenced("experience-restored")) return;
            int expected = alice ? 99 : 0;
            if (game.player.totalExperience != expected || orbs != 0) { client.fail("experience_lost_or_duplicated_on_reload"); return; }
            if (alice && (!game.player.getMainHandItem().isEnchanted() || game.player.getMainHandItem().getDamageValue() != 0)) { client.fail("mending_lost_on_reload"); return; }
            if (!client.screenshot("experience_after_reload").done()) return;
            oracle = new RemotePlayer(game.level, game.player.getGameProfile());
            oracle.totalExperience = game.player.totalExperience;
            oracle.experienceLevel = game.player.experienceLevel;
            oracle.experienceProgress = game.player.experienceProgress;
            phase = Phase.ARITHMETIC;
        }
        if (phase == Phase.ARITHMETIC) {
            if (arithmeticPending) {
                if (!arithmeticAcknowledged) return;
                if (game.player.totalExperience != oracle.totalExperience || game.player.experienceLevel != oracle.experienceLevel
                    || Float.floatToIntBits(game.player.experienceProgress) != Float.floatToIntBits(oracle.experienceProgress)) return;
                arithmeticStep++;
                arithmeticPending = false;
            }
            if (arithmeticStep == POINTS.length + LEVELS.length) {
                client.pass("experience_orbs_mending_reload_and_vanilla_arithmetic_verified");
                return;
            }
            boolean points = arithmeticStep < POINTS.length;
            int amount = points ? POINTS[arithmeticStep] : LEVELS[arithmeticStep - POINTS.length];
            if (points) oracle.giveExperiencePoints(amount); else oracle.giveExperienceLevels(amount);
            arithmeticAcknowledged = false;
            arithmeticPending = true;
            client.send((points ? "points " : "levels ") + amount);
        }
    }
}
