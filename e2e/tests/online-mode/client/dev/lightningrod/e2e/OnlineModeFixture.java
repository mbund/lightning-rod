package dev.lightningrod.e2e;

import java.nio.charset.StandardCharsets;
import java.util.Collection;
import java.util.UUID;
import net.minecraft.client.Minecraft;

/// Alice joins in online mode under the UUID the runner's session server knows her by, with the
/// textures it gave her; the session server says mallory never joined, so login refuses her.
final class OnlineModeFixture extends Fixture {
    // What the runner's session server gives every player it knows.
    private static final String TEXTURES = "eyJ0ZXh0dXJlcyI6e319";

    OnlineModeFixture(Recorder r) { super(r); }

    private boolean rejected() { return r.peer.equals("mallory"); }

    @Override void disconnected(Minecraft game, String title) {
        if (rejected() && r.playTick < 0 && r.joins == 0) client.pass("unverified_player_refused_at_login");
        else super.disconnected(game, title);
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (rejected()) {
            client.fail("unverified_player_admitted");
            return;
        }
        if (game.player == null || game.getConnection() == null) return;
        UUID expected = UUID.nameUUIDFromBytes(("OnlinePlayer:" + r.peer).getBytes(StandardCharsets.UTF_8));
        if (!game.player.getUUID().equals(expected)) {
            client.fail("offline_uuid_kept: " + game.player.getUUID());
            return;
        }
        var info = game.getConnection().getPlayerInfo(expected);
        if (info == null) return;
        String textures = texturesOf(info.getProfile());
        if (!TEXTURES.equals(textures)) {
            client.fail("textures_missing: " + textures);
            return;
        }
        client.pass("online_player_joined_with_session_profile");
    }

    /// The profile's textures value. Releases before 1.21.9 name the property map getProperties.
    private static String texturesOf(Object profile) {
        try {
            Object properties;
            try { properties = profile.getClass().getMethod("properties").invoke(profile); }
            catch (NoSuchMethodException legacy) { properties = profile.getClass().getMethod("getProperties").invoke(profile); }
            Collection<?> values = (Collection<?>) properties.getClass().getMethod("get", Object.class).invoke(properties, "textures");
            for (Object property : values) return (String) property.getClass().getMethod("value").invoke(property);
            return null;
        } catch (ReflectiveOperationException error) {
            return "unreadable: " + error;
        }
    }
}
