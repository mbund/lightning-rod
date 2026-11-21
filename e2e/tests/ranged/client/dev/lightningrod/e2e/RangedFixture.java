package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.world.item.Items;

/// Alice draws her bow for a second and a half and lets go: first at the cow ahead, then at
/// her feet.
final class RangedFixture extends Fixture {
    private enum Phase { WAITING, AIM, DOWN, VERIFIED }
    private Phase phase = Phase.WAITING;
    private int readyJoin = -1;
    private int drawn;
    private boolean shot;

    RangedFixture(Recorder r) { super(r); }

    @Override void message(String text) {
        phase = switch (text) {
            case "aim" -> Phase.AIM;
            case "down" -> Phase.DOWN;
            case "verified" -> Phase.VERIFIED;
            default -> throw new IllegalStateException("Unexpected ranged message " + text);
        };
        drawn = 0;
        shot = false;
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || game.gameMode == null || r.terrainTick < 0 || missing != 0) return;
        if (readyJoin != r.joins) { readyJoin = r.joins; client.send("ready"); return; }
        if (r.tick - r.terrainTick > 2400) { client.fail("ranged_timeout_" + phase); return; }
        if (phase == Phase.VERIFIED) { client.pass("arrow_hit_stuck_and_picked_up"); return; }
        if (phase == Phase.WAITING || shot) return;
        if (!game.player.getMainHandItem().is(Items.BOW)) return;
        game.player.setYRot(0);
        game.player.setXRot(phase == Phase.AIM ? 8 : 90);
        // Held for thirty ticks, a full draw, then let go.
        boolean holding = ++drawn < 30;
        game.options.keyUse.setDown(holding);
        if (!holding) shot = true;
    }
}
