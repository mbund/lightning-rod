package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;

final class FallDamageFixture extends Fixture {

    FallDamageFixture(Recorder r) { super(r); }

    public void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || !game.player.onGround() || game.player.getHealth() == 20) return;
        if (!close(game.player.getX(), 0.5, 0.01) || !close(game.player.getY(), 65, 0.01)
            || !close(game.player.getZ(), 0.5, 0.01) || !close(game.player.getHealth(), 15, 0.01)) {
            client.fail("incorrect_eight_block_fall");
            return;
        }
        if (!client.screenshot("fall_damage_received").done()) return;
        client.pass("eight_block_fall_five_damage");
    }

}
