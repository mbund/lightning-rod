package dev.lightningrod.e2e;

import net.minecraft.client.MinecraftClient;

final class FallDamageFixture extends Fixture {

    FallDamageFixture(Recorder r) { super(r); }

    public void tick(MinecraftClient client, int loaded, int missing) {
        if (r.terrainTick < 0 || !client.player.isOnGround() || client.player.getHealth() == 20) return;
        if (!r.close(client.player.getX(), 0.5, 0.01) || !r.close(client.player.getY(), 65, 0.01)
            || !r.close(client.player.getZ(), 0.5, 0.01) || !r.close(client.player.getHealth(), 15, 0.01)) {
            r.fail(client, "incorrect_eight_block_fall");
            return;
        }
        r.screenshot(client, "fall_damage_received");
        r.pass(client, "eight_block_fall_five_damage");
    }

}
