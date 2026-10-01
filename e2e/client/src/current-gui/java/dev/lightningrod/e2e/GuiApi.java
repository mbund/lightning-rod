package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.Overlay;
import net.minecraft.client.gui.components.BossHealthOverlay;
import net.minecraft.client.gui.components.toasts.ToastManager;
import com.mojang.blaze3d.pipeline.RenderTarget;

final class GuiApi {
    static Screen screen(Minecraft client) { return client.gui.screen(); }
    static void screen(Minecraft client, Screen screen) { client.gui.setScreen(screen); }
    static Overlay overlay(Minecraft client) { return client.gui.overlay(); }
    static BossHealthOverlay bossBars(Minecraft client) { return client.gui.hud.getBossOverlay(); }
    static ToastManager toasts(Minecraft client) { return client.gui.toastManager(); }
    static RenderTarget target(Minecraft client) { return client.gameRenderer.mainRenderTarget(); }
}
