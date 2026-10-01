package dev.lightningrod.e2e;

import java.nio.file.Files;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.core.component.DataComponents;
import net.minecraft.network.chat.Component;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.item.component.ItemLore;

final class ItemComponentsFixture extends Fixture {
    private int stage;
    private volatile int configurations;
    private boolean requested;
    private int settling;

    ItemComponentsFixture(Recorder recorder) { super(recorder); }

    @Override public void reconfigurationEncoded() { configurations++; }

    private ItemStack original(String owner) {
        var stack = new ItemStack(Items.PAPER);
        stack.set(DataComponents.CUSTOM_NAME, Component.literal(owner + "'s paper"));
        stack.set(DataComponents.LORE, new ItemLore(List.of(Component.literal("Original lore"))));
        return stack;
    }

    private boolean presented(Minecraft client, ItemStack stack, String owner, int price) {
        if (!stack.getHoverName().getString().equals(owner + "'s paper")) return false;
        var lore = stack.get(DataComponents.LORE);
        if (lore == null || lore.lines().size() != 2) return false;
        String recipient = client.player.getUUID().toString().replace("-", "").replaceFirst("^0+", "");
        return lore.lines().get(0).getString().equals("Original lore")
            && lore.lines().get(1).getString().equals("Price: " + price + " credits. Customer: " + recipient);
    }

    @Override public void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0 || r.missingChunks(client, 4) != 0) return;
        String other = r.peer.equals("alice") ? "bob" : "alice";
        var peer = client.level.players().stream()
            .filter(player -> ClientApi.profileName(player.getGameProfile()).equals(other)).findFirst().orElse(null);
        if (peer == null) return;
        if (r.tick % 100 == 0) r.event("component_probe", "stage", stage,
            "own", client.player.getMainHandItem().toString(), "own_lore", String.valueOf(client.player.getMainHandItem().get(DataComponents.LORE)),
            "peer_lore", String.valueOf(peer.getMainHandItem().get(DataComponents.LORE)));
        if (stage == 0) {
            boolean alice = r.peer.equals("alice");
            client.player.setPos(alice ? -3.5 : 3.5, 65, 0.5);
            client.player.setYRot(alice ? -90 : 90);
            client.player.setXRot(10);
            client.player.getInventory().setSelectedSlot(0);
            var stack = original(r.peer);
            client.player.getInventory().setItem(0, stack);
            client.gameMode.handleCreativeModeItemAdd(stack, 36);
            stage++;
        } else if (stage == 1) {
            if (!presented(client, client.player.getMainHandItem(), r.peer, 100)
                || !presented(client, peer.getMainHandItem(), other, 100)) return;
            r.marker(r.peer + ".initial");
            r.screenshot(client, "personalized_equipment");
            stage++;
        } else if (stage == 2) {
            if (!Files.exists(r.artifacts.resolve(other + ".initial"))) return;
            if (r.peer.equals("alice") && !requested) {
                client.getConnection().sendCommand("price_next");
                requested = true;
            }
            if (!presented(client, client.player.getMainHandItem(), r.peer, 200)
                || !presented(client, peer.getMainHandItem(), other, 200)) return;
            r.event("item_presentation", "phase", "price_changed", "price", 200);
            var moved = client.player.getMainHandItem().copy();
            client.player.getInventory().setItem(0, ItemStack.EMPTY);
            client.player.getInventory().setItem(1, moved);
            client.player.getInventory().setSelectedSlot(1);
            client.gameMode.handleCreativeModeItemAdd(ItemStack.EMPTY, 36);
            client.gameMode.handleCreativeModeItemAdd(moved, 37);
            var unsupported = new ItemStack(Items.PAPER);
            unsupported.set(DataComponents.INTANGIBLE_PROJECTILE, net.minecraft.util.Unit.INSTANCE);
            client.gameMode.handleCreativeModeItemAdd(unsupported, 38);
            client.getConnection().sendCommand("price_check");
            requested = false;
            stage++;
        } else if (stage == 3) {
            if (!r.receivedChat.contains("Price round trip verified")) return;
            if (!presented(client, client.player.getMainHandItem(), r.peer, 200)
                || !presented(client, peer.getMainHandItem(), other, 200)) return;
            r.marker(r.peer + ".roundtrip");
            stage++;
        } else if (stage == 4) {
            if (!Files.exists(r.artifacts.resolve(other + ".roundtrip"))) return;
            if (r.peer.equals("alice") && !requested) {
                client.getConnection().sendCommand("price_reload");
                requested = true;
            }
            if (configurations != 0) client.player.getInventory().setSelectedSlot(1);
            if (configurations == 0 || !presented(client, client.player.getMainHandItem(), r.peer, 100)
                || !presented(client, peer.getMainHandItem(), other, 100)) return;
            if (++settling < 10) return;
            r.screenshot(client, "components_after_reload");
            r.marker(r.peer + ".complete");
            stage++;
        } else if (Files.exists(r.artifacts.resolve(other + ".complete"))) {
            r.pass(client, "optional_components_personalized_lore_roundtrip_and_reload");
        }
    }
}
