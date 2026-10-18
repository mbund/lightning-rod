package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;

final class RespawnFixture extends Fixture {
    private net.minecraft.client.player.LocalPlayer deadPlayer;

    RespawnFixture(Recorder r) { super(r); }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (deadPlayer == null && game.player.getHealth() == 0) {
            if (!client.screenshot("before_respawn").done()) return;
            deadPlayer = game.player;
            game.player.respawn();
            GuiApi.screen(game, null);
        } else if (deadPlayer != null && game.player != deadPlayer && game.player.getHealth() == 20
            && game.player.onGround() && loaded >= 9 && close(game.player.getY(), 65, 0.01)) {
            if (!client.screenshot("after_respawn").done()) return;
            client.pass("respawn_restored_player_and_terrain");
        }

    }
}
