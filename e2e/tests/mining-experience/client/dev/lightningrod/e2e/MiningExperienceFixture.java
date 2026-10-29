package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.client.tutorial.TutorialSteps;
import net.minecraft.core.BlockPos;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.Items;
import net.minecraft.world.phys.Vec3;

final class MiningExperienceFixture extends Fixture {
    private enum Phase { WAITING, NORMAL, NORMAL_MINED, SILK, SILK_MINED, WRONG, WRONG_MINED, RELOADING, RESTORED }
    private static final BlockPos TARGET = new BlockPos(0, 66, 0);
    private Phase phase = Phase.WAITING;
    private int readyJoin;
    private int total;
    private boolean fenced;

    MiningExperienceFixture(Recorder recorder) { super(recorder); }
    @Override boolean encrypted() { return true; }
    @Override boolean prepare(Minecraft game) {
        game.getTutorial().setStep(TutorialSteps.NONE);
        return true;
    }
    @Override void message(String text) {
        if (text.startsWith("fence ")) return;
        phase = switch (text) {
            case "normal" -> Phase.NORMAL;
            case "normal_mined" -> Phase.NORMAL_MINED;
            case "silk" -> Phase.SILK;
            case "silk_mined" -> Phase.SILK_MINED;
            case "wrong" -> Phase.WRONG;
            case "wrong_mined" -> Phase.WRONG_MINED;
            case "restored" -> Phase.RESTORED;
            default -> throw new IllegalStateException("Unexpected mining message " + text);
        };
        fenced = false;
    }
    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || game.gameMode == null || r.terrainTick < 0 || missing != 0) return;
        if (readyJoin != r.joins) { readyJoin = r.joins; client.send("ready"); return; }
        if (phase == Phase.NORMAL || phase == Phase.SILK || phase == Phase.WRONG) {
            var held = game.player.getMainHandItem();
            if (!held.is(phase == Phase.WRONG ? Items.WOODEN_PICKAXE : Items.DIAMOND_PICKAXE)) return;
            if (held.isEnchanted() != (phase == Phase.SILK)) return;
            if (!game.level.getBlockState(TARGET).isAir()) {
                var delta = new Vec3(TARGET.getX() + 0.5, TARGET.getY() + 0.5, TARGET.getZ() + 0.5).subtract(game.player.getEyePosition());
                game.player.setYRot((float)Math.toDegrees(Math.atan2(-delta.x, delta.z)));
                game.player.setXRot((float)-Math.toDegrees(Math.atan2(delta.y, Math.hypot(delta.x, delta.z))));
                game.options.keyAttack.setDown(true);
            } else game.options.keyAttack.setDown(false);
            return;
        }
        game.options.keyAttack.setDown(false);
        if (phase == Phase.NORMAL_MINED || phase == Phase.SILK_MINED || phase == Phase.WRONG_MINED || phase == Phase.RESTORED) {
            if (!fenced) { client.fence(phase.name()); fenced = true; return; }
            if (!client.fenced(phase.name())) return;
            if (phase == Phase.NORMAL_MINED) {
                total = game.player.totalExperience;
                if (total < 3 || total > 7) { client.fail("ore_experience_range"); return; }
            } else if (game.player.totalExperience != total) { client.fail("unexpected_mining_experience_" + phase); return; }
            if (phase == Phase.SILK_MINED) {
                boolean ore = false;
                for (var entity : game.level.entitiesForRendering()) if (entity instanceof ItemEntity item && item.getItem().is(Items.DIAMOND_ORE)) ore = true;
                if (!ore) return;
            }
            if (!client.screenshot("mining_xp_" + phase.name().toLowerCase(java.util.Locale.ROOT)).done()) return;
            switch (phase) {
                case NORMAL_MINED -> { client.send("normal_verified"); phase = Phase.WAITING; }
                case SILK_MINED -> { client.send("silk_verified"); phase = Phase.WAITING; }
                case WRONG_MINED -> { client.send("wrong_verified"); phase = Phase.RELOADING; }
                case RESTORED -> client.pass("ore_xp_silk_touch_wrong_tool_and_reload_verified");
                default -> throw new IllegalStateException();
            }
        }
    }
}
