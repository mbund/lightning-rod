package dev.lightningrod.e2e;

import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.core.component.DataComponents;
import net.minecraft.network.chat.Component;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.item.component.ItemLore;

final class ItemComponentsFixture extends Fixture {
    private enum Phase { GIVE, INITIAL, PRICE, ROUNDTRIP, RELOAD, COMPLETE }
    private Phase phase = Phase.GIVE;
    private volatile int configurations;
    private boolean requested;

    ItemComponentsFixture(Recorder recorder) { super(recorder); }

    @Override public void reconfigurationEncoded() { configurations++; }

    private ItemStack original(String owner) {
        var stack = new ItemStack(Items.PAPER);
        stack.set(DataComponents.CUSTOM_NAME, Component.literal(owner + "'s paper"));
        stack.set(DataComponents.LORE, new ItemLore(List.of(Component.literal("Original lore"))));
        return stack;
    }

    private boolean presented(Minecraft game, ItemStack stack, String owner, int price) {
        if (!stack.getHoverName().getString().equals(owner + "'s paper")) return false;
        var lore = stack.get(DataComponents.LORE);
        if (lore == null || lore.lines().size() != 2) return false;
        String recipient = game.player.getUUID().toString().replace("-", "").replaceFirst("^0+", "");
        return lore.lines().get(0).getString().equals("Original lore")
            && lore.lines().get(1).getString().equals("Price: " + price + " credits. Customer: " + recipient);
    }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missingChunks(game, r.minimumRadius) != 0) return;
        String other = r.peer.equals("alice") ? "bob" : "alice";
        var peer = game.level.players().stream()
            .filter(player -> ClientApi.profileName(player.getGameProfile()).equals(other)).findFirst().orElse(null);
        if (peer == null) return;
        if (r.tick % 100 == 0) client.event("component_probe", "phase", phase,
            "own", game.player.getMainHandItem().toString(), "own_lore", String.valueOf(game.player.getMainHandItem().get(DataComponents.LORE)),
            "peer_lore", String.valueOf(peer.getMainHandItem().get(DataComponents.LORE)));
        if (phase == Phase.GIVE) {
            boolean alice = r.peer.equals("alice");
            game.player.setPos(alice ? -3.5 : 3.5, 65, 0.5);
            game.player.setYRot(alice ? -90 : 90);
            game.player.setXRot(10);
            game.player.getInventory().setSelectedSlot(0);
            var stack = original(r.peer);
            game.player.getInventory().setItem(0, stack);
            game.gameMode.handleCreativeModeItemAdd(stack, 36);
            phase = Phase.INITIAL;
        } else if (phase == Phase.INITIAL) {
            if (!presented(game, game.player.getMainHandItem(), r.peer, 100)
                || !presented(game, peer.getMainHandItem(), other, 100)) return;
            if (!client.screenshot("personalized_equipment").done()) return;
            client.mark(r.peer + ".initial");
            phase = Phase.PRICE;
        } else if (phase == Phase.PRICE) {
            if (!client.marked(other + ".initial")) return;
            if (r.peer.equals("alice") && !requested) {
                client.send("price_next");
                requested = true;
            }
            if (!presented(game, game.player.getMainHandItem(), r.peer, 200)
                || !presented(game, peer.getMainHandItem(), other, 200)) return;
            client.event("item_presentation", "phase", "price_changed", "price", 200);
            var moved = game.player.getMainHandItem().copy();
            game.player.getInventory().setItem(0, ItemStack.EMPTY);
            game.player.getInventory().setItem(1, moved);
            game.player.getInventory().setSelectedSlot(1);
            game.gameMode.handleCreativeModeItemAdd(ItemStack.EMPTY, 36);
            game.gameMode.handleCreativeModeItemAdd(moved, 37);
            var unsupported = new ItemStack(Items.PAPER);
            unsupported.set(DataComponents.INTANGIBLE_PROJECTILE, net.minecraft.util.Unit.INSTANCE);
            game.gameMode.handleCreativeModeItemAdd(unsupported, 38);
            client.send("price_check");
            requested = false;
            phase = Phase.ROUNDTRIP;
        } else if (phase == Phase.ROUNDTRIP) {
            if (!client.received("Price round trip verified")) return;
            if (!presented(game, game.player.getMainHandItem(), r.peer, 200)
                || !presented(game, peer.getMainHandItem(), other, 200)) return;
            client.mark(r.peer + ".roundtrip");
            phase = Phase.RELOAD;
        } else if (phase == Phase.RELOAD) {
            if (!client.marked(other + ".roundtrip")) return;
            if (r.peer.equals("alice") && !requested) {
                client.send("price_reload");
                requested = true;
            }
            if (configurations != 0) game.player.getInventory().setSelectedSlot(1);
            if (configurations == 0 || !presented(game, game.player.getMainHandItem(), r.peer, 100)
                || !presented(game, peer.getMainHandItem(), other, 100)) return;
            if (!client.screenshot("components_after_reload").done()) return;
            client.mark(r.peer + ".complete");
            phase = Phase.COMPLETE;
        } else if (client.marked(other + ".complete")) {
            client.pass("optional_components_personalized_lore_roundtrip_and_reload");
        }
    }
}
