package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.item.Items;

/// Alice waits for her sword to charge fully, standing still, and then strikes the cow the server
/// names. The server checks what the hit did.
final class MeleeFixture extends Fixture {
    private enum Phase { WAITING, ARMED, CHARGED, ATTACK, ATTACKED, VERIFIED }
    private Phase phase = Phase.WAITING;
    private int readyJoin = -1;
    private int target;
    private int charged;

    MeleeFixture(Recorder r) { super(r); }

    @Override void message(String text) {
        if (text.equals("armed")) phase = Phase.ARMED;
        else if (text.startsWith("attack ")) {
            target = Integer.parseInt(text.substring("attack ".length()));
            phase = Phase.ATTACK;
        } else if (text.equals("verified")) phase = Phase.VERIFIED;
        else throw new IllegalStateException("Unexpected melee message " + text);
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || game.gameMode == null || r.terrainTick < 0 || missing != 0) return;
        if (readyJoin != r.joins) { readyJoin = r.joins; client.send("ready"); return; }
        if (r.tick - r.terrainTick > 2400) { client.fail("melee_timeout_" + phase); return; }
        switch (phase) {
            case ARMED -> {
                if (!game.player.getMainHandItem().is(Items.DIAMOND_SWORD) || !game.player.onGround()) return;
                // Some ticks past full, so the server's count is full too.
                if (game.player.getAttackStrengthScale(0) < 1.0F || ++charged < 10) return;
                game.player.setYRot(180);
                game.player.setXRot(0);
                client.send("charged");
                phase = Phase.CHARGED;
            }
            case ATTACK -> {
                var entity = game.level.getEntity(target);
                if (entity == null) return;
                game.gameMode.attack(game.player, entity);
                game.player.swing(InteractionHand.MAIN_HAND);
                client.send("attacked");
                phase = Phase.ATTACKED;
            }
            case VERIFIED -> client.pass("sword_hit_swept_burned_and_wore");
            default -> {}
        }
    }
}
