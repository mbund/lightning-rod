package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.item.Items;

/// Bob faces Alice and holds his shield up. Alice swings her axe at full strength when the server
/// says, then stands where she started and swings again when it asks.
final class PvpFixture extends Fixture {
    private enum Phase { WAITING, ARMED, ATTACK, ATTACKED, AGAIN, VERIFIED }
    private Phase phase = Phase.WAITING;
    private int readyJoin = -1;
    private int target;
    private int charged;

    PvpFixture(Recorder r) { super(r); }

    private boolean alice() { return r.peer.equals("alice"); }

    @Override void message(String text) {
        if (text.equals("armed")) phase = Phase.ARMED;
        else if (text.startsWith("attack ")) {
            target = Integer.parseInt(text.substring("attack ".length()));
            phase = Phase.ATTACK;
        } else if (text.equals("again")) {
            charged = 0;
            phase = Phase.AGAIN;
        } else if (text.equals("verified")) phase = Phase.VERIFIED;
        else throw new IllegalStateException("Unexpected pvp message " + text);
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || game.gameMode == null || r.terrainTick < 0 || missing != 0) return;
        if (readyJoin != r.joins) { readyJoin = r.joins; client.send("ready"); return; }
        if (r.tick - r.terrainTick > 2400) { client.fail("pvp_timeout_" + phase); return; }
        if (phase == Phase.VERIFIED) { client.pass("axe_disabled_shield_then_hit"); return; }
        if (!alice()) {
            // Bob looks north at Alice and keeps his shield up.
            game.player.setYRot(180);
            game.player.setXRot(0);
            game.options.keyUse.setDown(phase != Phase.WAITING && game.player.getOffhandItem().is(Items.SHIELD));
            return;
        }
        game.player.setYRot(0);
        game.player.setXRot(0);
        if (phase == Phase.ATTACK || phase == Phase.AGAIN) {
            // The shield pushed her back; she steps up again before the second swing.
            if (phase == Phase.AGAIN) game.player.setPos(0.5, 65, 0.5);
            if (!game.player.getMainHandItem().is(Items.DIAMOND_AXE) || !game.player.onGround()) return;
            if (game.player.getAttackStrengthScale(0) < 1.0F || ++charged < 10) return;
            var entity = game.level.getEntity(target);
            if (entity == null) return;
            game.gameMode.attack(game.player, entity);
            game.player.swing(InteractionHand.MAIN_HAND);
            client.send("attacked");
            phase = Phase.ATTACKED;
        }
    }
}
