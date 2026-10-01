package dev.lightningrod.e2e;

import com.mojang.authlib.GameProfile;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.input.MouseButtonInfo;

final class ClientApi {
    static long window(net.minecraft.client.Minecraft client) { return client.getWindow().handle(); }
    static String profileName(GameProfile profile) { return profile.name(); }

    static void click(Screen screen, double x, double y) {
        var click = new MouseButtonEvent(x, y, new MouseButtonInfo(0, 0));
        screen.mouseClicked(click, false);
        screen.mouseReleased(click);
    }
}
