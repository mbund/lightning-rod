package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import dev.lightningrod.e2e.mixin.MouseHandlerAccessor;
import net.fabricmc.fabric.api.client.item.v1.ItemTooltipCallback;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import org.lwjgl.glfw.GLFW;
import net.minecraft.client.tutorial.TutorialSteps;
import net.minecraft.core.BlockPos;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.entity.LightningBolt;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.Items;
import net.minecraft.world.phys.Vec3;

final class EnchantmentsFixture extends Fixture {
    private enum Phase { WAITING, NORMAL, NORMAL_DONE, SILK, SILK_DONE, PLAIN, ENCHANTED, LIGHTNING, RESTORED }
    private static final BlockPos SPAWNER = new BlockPos(0, 66, 0);
    private static final BlockPos TARGET = new BlockPos(0, 65, -8);
    private Phase phase = Phase.WAITING;
    private int readyJoin;
    private boolean used;
    private boolean fenced;
    private boolean lightningSeen;
    private boolean tooltipSeen;
    private boolean tooltipCaptured;

    EnchantmentsFixture(Recorder r) {
        super(r);
        ItemTooltipCallback.EVENT.register((stack, context, type, lines) -> {
            if (stack.is(Items.STICK) && stack.isEnchanted()) tooltipSeen = lines.stream().anyMatch(line -> line.getString().contains("Storm Calling"));
        });
    }
    @Override boolean encrypted() { return true; }
    @Override boolean prepare(Minecraft game) {
        game.getTutorial().setStep(TutorialSteps.NONE);
        return true;
    }
    @Override void message(String text) {
        if (text.startsWith("fence ")) return;
        phase = switch (text) {
            case "normal" -> Phase.NORMAL;
            case "normal_done" -> Phase.NORMAL_DONE;
            case "silk" -> Phase.SILK;
            case "silk_done" -> Phase.SILK_DONE;
            case "plain" -> Phase.PLAIN;
            case "enchanted" -> Phase.ENCHANTED;
            case "lightning" -> Phase.LIGHTNING;
            case "restored" -> Phase.RESTORED;
            default -> throw new IllegalStateException("Unexpected enchantment message " + text);
        };
        used = false;
        fenced = false;
    }
    private void look(Minecraft game, BlockPos target) {
        Vec3 delta = Vec3.atCenterOf(target).subtract(game.player.getEyePosition());
        game.player.setYRot((float)Math.toDegrees(Math.atan2(-delta.x, delta.z)));
        game.player.setXRot((float)-Math.toDegrees(Math.atan2(delta.y, Math.hypot(delta.x, delta.z))));
    }
    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || game.gameMode == null || r.terrainTick < 0 || missing != 0) return;
        for (var entity : game.level.entitiesForRendering()) if (entity instanceof LightningBolt) {
            if (Math.abs(entity.getX() - 0.5) > 0.1 || Math.abs(entity.getZ() + 7.0) > 0.1) { client.fail("lightning_at_wrong_position"); return; }
            lightningSeen = true;
        }
        if (readyJoin != r.joins) { readyJoin = r.joins; client.send("ready"); return; }
        if (phase == Phase.NORMAL || phase == Phase.SILK) {
            var held = game.player.getMainHandItem();
            if (!held.is(Items.DIAMOND_PICKAXE) || held.isEnchanted() != (phase == Phase.SILK)) return;
            if (phase == Phase.SILK && game.player.getAttributeValue(Attributes.MINING_EFFICIENCY) != 26.0) return;
            look(game, SPAWNER);
            game.options.keyAttack.setDown(!game.level.getBlockState(SPAWNER).isAir());
            return;
        }
        game.options.keyAttack.setDown(false);
        if (phase == Phase.NORMAL_DONE || phase == Phase.SILK_DONE) {
            if (!fenced) { client.fence(phase.name()); fenced = true; return; }
            if (!client.fenced(phase.name())) return;
            if (!game.level.getBlockState(SPAWNER).isAir()) { client.fail("spawner_not_broken"); return; }
            boolean dropped = false;
            for (var entity : game.level.entitiesForRendering()) if (entity instanceof ItemEntity item && item.getItem().is(Items.SPAWNER)) dropped = true;
            if (phase == Phase.SILK_DONE && !dropped) return;
            if (phase == Phase.NORMAL_DONE && dropped) { client.fail("unenchanted_spawner_dropped"); return; }
            if (!client.screenshot(phase == Phase.SILK_DONE ? "silk_touch_spawner" : "ordinary_spawner").done()) return;
            client.send(phase == Phase.SILK_DONE ? "silk_verified" : "normal_verified");
            phase = Phase.WAITING;
        } else if (phase == Phase.PLAIN || phase == Phase.ENCHANTED) {
            var held = game.player.getMainHandItem();
            if (!held.is(Items.STICK) || held.isEnchanted() != (phase == Phase.ENCHANTED)) return;
            look(game, TARGET);
            if (phase == Phase.ENCHANTED && !tooltipCaptured) {
                if (GuiApi.screen(game) == null) GuiApi.screen(game, new InventoryScreen(game.player));
                var screen = GuiApi.screen(game);
                var slot = game.player.containerMenu.getSlot(36);
                double x = (screen.width - 176) / 2 + slot.x + 8;
                double y = (screen.height - 166) / 2 + slot.y + 8;
                int[] width = new int[1], height = new int[1];
                GLFW.glfwGetWindowSize(ClientApi.window(game), width, height);
                ((MouseHandlerAccessor)game.mouseHandler).lightningRod$move(ClientApi.window(game), x * width[0] / screen.width, y * height[0] / screen.height);
                if (!tooltipSeen || !client.screenshot("storm_calling_tooltip").done()) return;
                GuiApi.screen(game, null);
                tooltipCaptured = true;
                return;
            }
            if (!used) { game.gameMode.useItem(game.player, InteractionHand.MAIN_HAND); used = true; return; }
            if (phase == Phase.PLAIN) {
                if (!fenced) { client.fence("plain_stick"); fenced = true; return; }
                if (!client.fenced("plain_stick")) return;
                if (lightningSeen) { client.fail("unenchanted_stick_cast"); return; }
                client.send("plain_used");
                phase = Phase.WAITING;
            }
        } else if (phase == Phase.LIGHTNING) {
            if (!lightningSeen || !client.screenshot("custom_enchantment_lightning").done()) return;
            client.send("lightning_verified");
            phase = Phase.WAITING;
        } else if (phase == Phase.RESTORED) {
            var held = game.player.getMainHandItem();
            if (!held.is(Items.STICK) || !held.isEnchanted()) return;
            if (!client.screenshot("custom_enchantment_after_reload").done()) return;
            client.pass("silk_spawners_custom_stick_lightning_and_reload_verified");
        }
    }
}
