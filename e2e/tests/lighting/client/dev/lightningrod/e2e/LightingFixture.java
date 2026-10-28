package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.block.Blocks;

final class LightingFixture extends Fixture {
    private enum Phase { WAITING, LIT, OBSTRUCTED, DARK, OPENED, CLOSED, RESTORED, RELOADED }
    private static final BlockPos TARGET = new BlockPos(17, 66, 2);
    private static final BlockPos SOURCE = new BlockPos(15, 66, 2);
    private static final BlockPos OBSTRUCTION = new BlockPos(16, 66, 2);
    private static final BlockPos OPENING = new BlockPos(17, 69, 2);
    private Phase phase = Phase.WAITING;
    private boolean acknowledged;
    private int readyJoin;
    private long startedNs;

    LightingFixture(Recorder r) { super(r); }

    @Override boolean prepare(Minecraft game) {
        game.getTutorial().setStep(net.minecraft.client.tutorial.TutorialSteps.NONE);
        return true;
    }

    @Override void message(String text) {
        phase = Phase.valueOf(text.toUpperCase(java.util.Locale.ROOT));
        acknowledged = false;
    }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (game.level == null || game.player == null || GuiApi.screen(game) != null || r.terrainTick < 0) return;
        if (startedNs == 0) startedNs = System.nanoTime();
        if (System.nanoTime() - startedNs > 60_000_000_000L) {
            client.fail("lighting_timeout_" + phase + "_block_" + game.level.getBrightness(LightLayer.BLOCK, TARGET)
                + "_sky_" + game.level.getBrightness(LightLayer.SKY, TARGET));
            return;
        }
        if (readyJoin != r.joins) {
            readyJoin = r.joins;
            client.send("ready");
            return;
        }
        if (phase == Phase.WAITING || acknowledged || !game.level.hasChunkAt(TARGET)) return;
        boolean emitter = phase == Phase.LIT || phase == Phase.OBSTRUCTED || phase == Phase.RESTORED || phase == Phase.RELOADED;
        if (!game.level.getBlockState(SOURCE).is(emitter ? Blocks.GLOWSTONE : Blocks.AIR)) return;
        if (!game.level.getBlockState(OBSTRUCTION).is(phase == Phase.OBSTRUCTED ? Blocks.STONE : Blocks.AIR)) return;
        if (!game.level.getBlockState(OPENING).is(phase == Phase.OPENED ? Blocks.AIR : Blocks.STONE)) return;
        int block = phase == Phase.OBSTRUCTED ? 11 : emitter ? 13 : 0;
        int sky = phase == Phase.OPENED ? 15 : 0;
        if (game.level.getBrightness(LightLayer.BLOCK, TARGET) != block
                || game.level.getBrightness(LightLayer.SKY, TARGET) != sky) return;
        if (phase == Phase.RELOADED && (r.joins != 2 || game.level.players().size() != 2)) return;
        if (!client.screenshot("lighting_" + phase.name().toLowerCase(java.util.Locale.ROOT)).done()) return;
        acknowledged = true;
        if (phase == Phase.RELOADED) client.pass("cross_chunk_emitters_occlusion_skylight_reload_verified");
        else client.send("observed");
    }
}
