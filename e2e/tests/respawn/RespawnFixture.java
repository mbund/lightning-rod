package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;

final class RespawnFixture extends Fixture {
    private net.minecraft.client.player.LocalPlayer deadPlayer;

    RespawnFixture(Recorder r) { super(r); }

    @Override public void tick(Minecraft client, int loaded, int missing) {
        if (deadPlayer == null && client.player.getHealth() == 0) {
            deadPlayer = client.player;
            r.screenshot(client, "before_respawn");
            client.player.respawn();
            GuiApi.screen(client, null);
        } else if (deadPlayer != null && client.player != deadPlayer && client.player.getHealth() == 20
            && client.player.onGround() && loaded >= 9 && r.close(client.player.getY(), 65, 0.01)) {
            r.screenshot(client, "after_respawn");
            r.pass(client, "respawn_restored_player_and_terrain");
        }

    }
}
