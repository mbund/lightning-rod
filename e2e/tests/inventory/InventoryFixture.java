package dev.lightningrod.e2e;

import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.CreativeModeTab;
import net.minecraft.world.item.ItemStack;

final class InventoryFixture extends Fixture {
    private record Click(int slot, int button, ClickType type) {}
    private record Case(String name, String setup, Click... clicks) {}
    private final List<Case> cases = new ArrayList<>();
    private int test;
    private int step = -2;
    private long nextAction;
    private ItemStack[] expected;
    private boolean checking;
    private final List<String> failures = new ArrayList<>();
    private int dropped;
    private int passed;

    InventoryFixture(Recorder r) {
        super(r);
        cases.add(new Case("pickup_place", "36/minecraft:bread/17", pick(36, 0), pick(37, 0)));
        cases.add(new Case("split_merge", "36/minecraft:bread/17", pick(36, 1), pick(37, 0), pick(36, 0), pick(37, 0)));
        cases.add(new Case("right_place_one", "36/minecraft:bread/17", pick(36, 0), pick(37, 1), pick(38, 1), pick(36, 0)));
        cases.add(new Case("stack_limit", "36/minecraft:bread/17 37/minecraft:bread/60", pick(36, 0), pick(37, 0), pick(36, 0)));
        cases.add(new Case("different_items", "36/minecraft:bread/17 37/minecraft:stone/9", pick(36, 0), pick(37, 0), pick(36, 0)));
        cases.add(new Case("unstackable", "36/minecraft:iron_pickaxe/1 37/minecraft:iron_pickaxe/1", pick(36, 0), pick(37, 0), pick(36, 0)));
        cases.add(new Case("empty_slot", "", pick(36, 0), pick(36, 1)));
        cases.add(new Case("shift_hotbar", "36/minecraft:bread/17", click(36, 0, ClickType.QUICK_MOVE), click(9, 0, ClickType.QUICK_MOVE)));
        cases.add(new Case("shift_partial", "9/minecraft:bread/60 36/minecraft:bread/17", click(36, 0, ClickType.QUICK_MOVE)));
        cases.add(new Case("number_swap", "9/minecraft:stone/9 36/minecraft:bread/17", click(9, 0, ClickType.SWAP), click(9, 8, ClickType.SWAP)));
        cases.add(new Case("offhand_swap", "36/minecraft:bread/17 45/minecraft:stone/9", click(36, 40, ClickType.SWAP), pick(45, 1), pick(37, 0)));
        cases.add(new Case("shift_offhand", "45/minecraft:bread/17", click(45, 0, ClickType.QUICK_MOVE)));
        cases.add(new Case("double_collect", "9/minecraft:bread/64 10/minecraft:bread/8 36/minecraft:bread/1 45/minecraft:bread/7", pick(36, 0), click(36, 0, ClickType.PICKUP_ALL)));
        cases.add(new Case("drag_left", "36/minecraft:bread/17", pick(36, 0), drag(-999, 0), drag(9, 1), drag(10, 1), drag(11, 1), drag(-999, 2), pick(36, 0)));
        cases.add(new Case("drag_right", "36/minecraft:bread/17", pick(36, 0), drag(-999, 4), drag(9, 5), drag(10, 5), drag(11, 5), drag(-999, 6), pick(36, 0)));
        cases.add(new Case("drag_partial", "9/minecraft:bread/63 10/minecraft:stone/4 36/minecraft:bread/17", pick(36, 0), drag(-999, 0), drag(9, 1), drag(10, 1), drag(11, 1), drag(-999, 2), pick(36, 0)));
        cases.add(new Case("drag_too_few", "36/minecraft:bread/2", pick(36, 0), drag(-999, 0), drag(9, 1), drag(10, 1), drag(11, 1), drag(-999, 2), pick(36, 0)));
        cases.add(new Case("drop_slot", "36/minecraft:bread/17", click(36, 0, ClickType.THROW), click(36, 1, ClickType.THROW)));
        cases.add(new Case("drop_cursor", "36/minecraft:bread/17", pick(36, 0), pick(-999, 1), pick(-999, 0)));
        cases.add(new Case("armor_accept", "36/minecraft:iron_helmet/1", pick(36, 0), pick(5, 0), pick(5, 0), pick(36, 0)));
        cases.add(new Case("armor_reject", "36/minecraft:bread/17", pick(36, 0), pick(5, 0), pick(6, 0), pick(36, 0)));
        cases.add(new Case("armor_shift", "36/minecraft:iron_helmet/1", click(36, 0, ClickType.QUICK_MOVE), click(5, 0, ClickType.QUICK_MOVE)));
        cases.add(new Case("armor_number", "36/minecraft:iron_helmet/1 37/minecraft:bread/17", click(5, 0, ClickType.SWAP), click(5, 1, ClickType.SWAP)));
        cases.add(new Case("craft_input", "36/minecraft:bread/17", pick(36, 0), pick(1, 1), pick(2, 1), pick(0, 0), pick(36, 0), click(1, 0, ClickType.QUICK_MOVE)));
        cases.add(new Case("clone", "36/minecraft:bread/17", click(36, 2, ClickType.CLONE), pick(37, 0)));
        cases.add(new Case("clone_held", "36/minecraft:bread/17 37/minecraft:stone/9", pick(36, 0), click(37, 2, ClickType.CLONE), pick(36, 0)));
        cases.add(new Case("drag_fill", "36/minecraft:bread/17", pick(36, 0), drag(-999, 8), drag(9, 9), drag(10, 9), drag(-999, 10), pick(36, 0)));
        cases.add(new Case("throw_held", "36/minecraft:bread/17 37/minecraft:stone/9", pick(36, 0), click(37, 0, ClickType.THROW), pick(36, 0)));
        cases.add(new Case("number_self", "36/minecraft:bread/17", click(36, 0, ClickType.SWAP)));
        String full = "36/minecraft:bread/17";
        for (int slot = 9; slot < 45; slot++) if (slot != 36) full += " " + slot + "/minecraft:stone/64";
        cases.add(new Case("shift_full", full, click(36, 0, ClickType.QUICK_MOVE)));
        cases.add(new Case("close_cursor", "36/minecraft:bread/17", pick(36, 0), new Click(-1, 0, null)));
        cases.add(new Case("craft_close", "36/minecraft:bread/17", pick(36, 0), pick(1, 1), pick(36, 0), new Click(-1, 0, null)));
        cases.add(new Case("armor_stack", "36/minecraft:carved_pumpkin/10", pick(36, 0), pick(5, 0), pick(36, 0)));
        cases.add(new Case("armor_stack_shift", "36/minecraft:carved_pumpkin/10", click(36, 0, ClickType.QUICK_MOVE)));
        cases.add(new Case("armor_stack_number", "36/minecraft:carved_pumpkin/10", click(5, 0, ClickType.SWAP)));
        cases.add(new Case("creative_delete", "36/minecraft:bread/17", pick(36, 0), pick(46, 0)));
        cases.add(new Case("creative_delete_all", "36/minecraft:bread/17 9/minecraft:stone/9", click(46, 0, ClickType.QUICK_MOVE)));
    }

    public void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0 || System.nanoTime() < nextAction) return;
        boolean creative = client.player.hasInfiniteMaterials();
        if (test == cases.size()) {
            if (failures.isEmpty()) r.pass(client, "inventory_actions_and_authoritative_slots_verified_" + passed);
            else r.fail(client, "inventory_cases_failed_" + String.join(",", failures));
            return;
        }
        Case current = cases.get(test);
        if (!creative && current.name.startsWith("creative_")) {
            test++;
            return;
        }
        if (creative && current.name.startsWith("craft_")) {
            test++;
            return;
        }
        String label = current.name + "_" + step;
        if (step == -2) {
            if (creative) client.player.containerMenu.setCarried(ItemStack.EMPTY);
            client.player.closeContainer();
            client.getConnection().sendCommand("inventory_setup " + current.name + " " + current.setup);
            step = -1;
        } else if (step == -1) {
            if (!r.receivedChat.contains("Inventory " + current.name + " ready")) return;
            if (!matchesSetup(client, current.setup)) return;
            GuiApi.screen(client, creative ? new CreativeScreen(client) : new InventoryScreen(client.player));
            if (creative && test != 0) ((CreativeScreen)GuiApi.screen(client)).inventoryTab();
            expected = snapshot(client);
            dropped = 0;
            for (var entity : client.level.entitiesForRendering()) if (entity instanceof ItemEntity item) dropped += item.getItem().getCount();
            step = 0;
        } else if (checking) {
            if (r.receivedChat.contains("Inventory " + label + " mismatch")) {
                failed(client, label + "_server");
                return;
            }
            if (!r.receivedChat.contains("Inventory " + label + " verified")) return;
            checking = false;
            step++;
            if (step == current.clicks.length) {
                passed++;
                r.event("inventory_case", "name", current.name, "creative", creative, "passed", true);
                r.screenshot(client, current.name);
                test++;
                step = -2;
            }
        } else {
            if (!equal(client, expected, label + "_before")) return;
            int before = 0;
            for (ItemStack stack : expected) before += stack.getCount();
            // Consecutive drag packets form one gesture. Do not wait for a server response mid-drag.
            do {
                Click action = current.clicks[step];
                if (action.type == null) {
                    client.player.closeContainer();
                    expected = snapshot(client);
                    if (!creative) {
                        expected[36] = new ItemStack(net.minecraft.world.item.Items.BREAD, 17);
                        expected[1] = ItemStack.EMPTY;
                        expected[46] = ItemStack.EMPTY;
                    } else {
                        expected[46] = new ItemStack(net.minecraft.world.item.Items.BREAD, 17);
                        client.getConnection().sendCommand("inventory_refresh");
                    }
                    checking = true;
                    nextAction = System.nanoTime() + 200_000_000L;
                    return;
                }
                if (GuiApi.screen(client) instanceof CreativeScreen screen) screen.click(action);
                else GameApi.inventoryClick(client, action.slot, action.button, action.type);
                if (action.type != ClickType.QUICK_CRAFT || action.button % 4 == 2) break;
                step++;
            } while (step < current.clicks.length);
            expected = snapshot(client);
            if (current.name.startsWith("drop_")) {
                int after = 0;
                for (ItemStack stack : expected) after += stack.getCount();
                dropped += before - after;
            }
            checking = true;
            nextAction = System.nanoTime() + 200_000_000L;
            return;
        }
        nextAction = System.nanoTime() + 200_000_000L;
    }

    @Override public void poll(Minecraft client) {
        if (!checking || client.player == null || System.nanoTime() < nextAction) return;
        String label = cases.get(test).name + "_" + step;
        if (!equal(client, expected, label)) return;
        String marker = "Inventory " + label + " requested";
        if (!r.receivedChat.contains(marker)) {
            r.receivedChat.add(marker);
            StringBuilder command = new StringBuilder("inventory_check ").append(label);
            String name = cases.get(test).name;
            if (client.player.hasInfiniteMaterials() && !name.startsWith("clone") && !name.equals("drag_fill") && !name.equals("creative_delete_all")) {
                ItemStack recovery = name.equals("creative_delete") ? new ItemStack(net.minecraft.world.item.Items.BREAD, 17) : expected[46];
                command.append(" pending/").append(recovery.isEmpty() ? "empty" : BuiltInRegistries.ITEM.getKey(recovery.getItem()))
                    .append('/').append(recovery.getCount());
            }
            for (int slot = 0; slot < expected.length; slot++) {
                ItemStack stack = expected[slot];
                if (!stack.isEmpty()) command.append(' ').append(slot).append('/').append(BuiltInRegistries.ITEM.getKey(stack.getItem())).append('/').append(stack.getCount());
            }
            if (cases.get(test).name.startsWith("drop_")) {
                int actual = 0;
                for (var entity : client.level.entitiesForRendering()) if (entity instanceof ItemEntity item) actual += item.getItem().getCount();
                if (actual != dropped) {
                    failed(client, label + "_dropped_items_expected_" + dropped + "_actual_" + actual);
                    return;
                }
                command.append(" drops/").append(dropped);
            }
            client.getConnection().sendCommand(command.toString());
        }
    }

    private boolean equal(Minecraft client, ItemStack[] wanted, String label) {
        ItemStack[] actual = snapshot(client);
        for (int slot = 0; slot < wanted.length; slot++) {
            if (!ItemStack.matches(wanted[slot], actual[slot])) {
                r.event("inventory_mismatch", "case", label, "slot", slot, "expected", wanted[slot].toString(), "actual", actual[slot].toString());
                failed(client, label + "_slot_" + slot);
                return false;
            }
        }
        return true;
    }

    private void failed(Minecraft client, String label) {
        failures.add(label);
        r.screenshot(client, label);
        checking = false;
        test++;
        step = -2;
        nextAction = System.nanoTime() + 200_000_000L;
    }

    private static ItemStack[] snapshot(Minecraft client) {
        ItemStack[] result = new ItemStack[47];
        for (int slot = 0; slot < 46; slot++) result[slot] = client.player.inventoryMenu.getSlot(slot).getItem().copy();
        result[46] = client.player.containerMenu.getCarried().copy();
        return result;
    }

    private static boolean matchesSetup(Minecraft client, String setup) {
        String[] entries = setup.isEmpty() ? new String[0] : setup.split(" ");
        for (int slot = 0; slot < 46; slot++) {
            String name = "empty";
            int count = 0;
            for (String entry : entries) {
                String[] parts = entry.split("/");
                if (Integer.parseInt(parts[0]) != slot) continue;
                name = parts[1];
                count = Integer.parseInt(parts[2]);
                break;
            }
            ItemStack stack = client.player.inventoryMenu.getSlot(slot).getItem();
            if (stack.getCount() != count) return false;
            if (!stack.isEmpty() && !BuiltInRegistries.ITEM.getKey(stack.getItem()).toString().equals(name)) return false;
        }
        return true;
    }

    private static Click pick(int slot, int button) { return click(slot, button, ClickType.PICKUP); }
    private static Click drag(int slot, int button) { return click(slot, button, ClickType.QUICK_CRAFT); }
    private static Click click(int slot, int button, ClickType type) { return new Click(slot, button, type); }

    static final class CreativeScreen extends CreativeModeInventoryScreen {
        CreativeScreen(Minecraft client) {
            super(client.player, client.player.connection.enabledFeatures(), false);
        }

        void inventoryTab() {
            selectTab(CreativeModeTab.Type.INVENTORY);
        }

        void catalogTab() {
            selectTab(CreativeModeTab.Type.CATEGORY);
        }

        private void selectTab(CreativeModeTab.Type type) {
            var tab = BuiltInRegistries.CREATIVE_MODE_TAB.stream().filter(group -> group.getType() == type).findFirst().orElseThrow();
            for (int px = 0; px < imageWidth; px += 4) {
                for (int py = -32; py < imageHeight + 32; py += 4) {
                    if (!checkTabClicked(tab, px, py)) continue;
                    ClientApi.click(this, leftPos + px, topPos + py);
                    if (isInventoryOpen() != (type == CreativeModeTab.Type.INVENTORY)) throw new IllegalStateException("creative tab not selected");
                    return;
                }
            }
            throw new IllegalStateException("creative inventory tab not found");
        }

        void click(Click action) {
            int slot = action.slot;
            if (!isInventoryOpen() && slot >= 36 && slot < 45) slot += 9;
            slotClicked(slot < 0 ? null : menu.slots.get(slot), slot, action.button, GameApi.click(action.type));
        }

        void pickSlot(int slot) { click(pick(slot, 0)); }
    }
}
