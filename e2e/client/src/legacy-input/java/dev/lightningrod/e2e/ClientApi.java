package dev.lightningrod.e2e;

import com.mojang.authlib.GameProfile;
import net.minecraft.client.gui.screens.Screen;

final class ClientApi {
    static long window(net.minecraft.client.Minecraft client) { return client.getWindow().getWindow(); }
    static String profileName(GameProfile profile) { return profile.getName(); }

    static void click(Screen screen, double x, double y) {
        screen.mouseClicked(x, y, 0);
        screen.mouseReleased(x, y, 0);
    }
}
