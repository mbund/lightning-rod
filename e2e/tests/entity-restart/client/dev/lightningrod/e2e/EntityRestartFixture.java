package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;

/** Tells the server when the terrain is in, before and after it reloads, and passes once the server finds every kind of entity it made back as it was. */
final class EntityRestartFixture extends Fixture {
    private int readyJoin;
    private boolean verified;

    EntityRestartFixture(Recorder recorder) { super(recorder); }
    @Override int renderDistance() { return 4; }

    @Override void message(String text) {
        if (text.equals("verified")) verified = true;
        else throw new IllegalArgumentException("unexpected entity restart message: " + text);
    }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || r.terrainTick < 0 || GuiApi.screen(game) != null) return;
        if (verified) {
            client.pass("entities_restored_after_reload");
            return;
        }
        if (r.joins > 2) {
            client.fail("unexpected_additional_reload");
            return;
        }
        if (loaded == 0 || missing != 0) return;
        if (readyJoin != r.joins) {
            readyJoin = r.joins;
            client.send("terrain_ready");
        }
    }
}
