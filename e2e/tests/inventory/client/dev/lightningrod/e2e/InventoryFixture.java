package dev.lightningrod.e2e;

import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.ItemStack;

final class InventoryFixture extends Fixture {
    private static final int BREAD_COUNT = 17;
    private record Click(int slot, int button, ClickType type) {}
    private record Case(String name, String setup, Click... clicks) {}
    private final List<Case> cases = new ArrayList<>();
    private int test;
    private enum Phase { CLOSE_MENU, WAIT_CLOSE, WAIT_SETUP, CLICK, WAIT_CHECK }
    private Phase phase = Phase.CLOSE_MENU;
    private int clickIndex;
    private ItemStack[] expected;
    private String requested;
    private final List<String> failures = new ArrayList<>();
    private int dropped;
    private int passed;
    private String pendingFailure;

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

    public void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0) return;
        if (pendingFailure != null) { failed(game, pendingFailure); return; }
        boolean creative = game.player.hasInfiniteMaterials();
        if (test == cases.size()) {
            if (failures.isEmpty()) client.pass("inventory_actions_and_authoritative_slots_verified_" + passed);
            else client.fail("inventory_cases_failed_" + String.join(",", failures));
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
        String label = current.name + "_" + clickIndex;
        if (phase == Phase.CLOSE_MENU) {
            if (creative) game.player.containerMenu.setCarried(ItemStack.EMPTY);
            game.player.closeContainer();
            client.fence("inventory-close-" + current.name);
            phase = Phase.WAIT_CLOSE;
        } else if (phase == Phase.WAIT_CLOSE) {
            if (!client.fenced("inventory-close-" + current.name)) return;
            client.send("inventory_setup " + current.name + " " + current.setup);
            phase = Phase.WAIT_SETUP;
        } else if (phase == Phase.WAIT_SETUP) {
            if (!client.received("Inventory " + current.name + " ready")) return;
            if (!matchesSetup(game, current.setup)) return;
            GuiApi.screen(game, creative ? new CreativeInventory(game) : new InventoryScreen(game.player));
            if (creative && test != 0) ((CreativeInventory)GuiApi.screen(game)).inventoryTab();
            expected = snapshot(game);
            dropped = 0;
            for (var entity : game.level.entitiesForRendering()) if (entity instanceof ItemEntity item) dropped += item.getItem().getCount();
            clickIndex = 0;
            phase = Phase.CLICK;
        } else if (phase == Phase.WAIT_CHECK) {
            if (client.received("Inventory " + label + " mismatch")) {
                failed(game, label + "_server");
                return;
            }
            if (!client.received("Inventory " + label + " verified")) return;
            if (clickIndex + 1 == current.clicks.length && !client.screenshot(current.name).done()) return;
            phase = Phase.CLICK;
            clickIndex++;
            if (clickIndex == current.clicks.length) {
                passed++;
                client.event("inventory_case", "name", current.name, "creative", creative, "passed", true);
                test++;
                clickIndex = 0;
                phase = Phase.CLOSE_MENU;
            }
        } else {
            if (!equal(game, expected, label + "_before")) return;
            int before = 0;
            for (ItemStack stack : expected) before += stack.getCount();
            // Consecutive drag packets form one gesture. Do not wait for a server response mid-drag.
            do {
                Click action = current.clicks[clickIndex];
                if (action.type == null) {
                    game.player.closeContainer();
                    expected = snapshot(game);
                    if (!creative) {
                        expected[36] = new ItemStack(net.minecraft.world.item.Items.BREAD, BREAD_COUNT);
                        expected[1] = ItemStack.EMPTY;
                        expected[46] = ItemStack.EMPTY;
                    }
                    phase = Phase.WAIT_CHECK;
                    client.fence("inventory-" + current.name + "-" + clickIndex);
                    return;
                }
                if (GuiApi.screen(game) instanceof CreativeInventory screen) screen.click(action.slot, action.button, action.type);
                else GameApi.inventoryClick(game, action.slot, action.button, action.type);
                if (action.type != ClickType.QUICK_CRAFT || action.button % 4 == 2) break;
                clickIndex++;
            } while (clickIndex < current.clicks.length);
            expected = snapshot(game);
            if (current.name.startsWith("drop_")) {
                int after = 0;
                for (ItemStack stack : expected) after += stack.getCount();
                dropped += before - after;
            }
            phase = Phase.WAIT_CHECK;
            client.fence("inventory-" + current.name + "-" + clickIndex);
            return;
        }
    }

    @Override public void poll(Minecraft game) {
        if (pendingFailure != null) return;
        if (phase != Phase.WAIT_CHECK || game.player == null || !client.fenced("inventory-" + cases.get(test).name + "-" + clickIndex)) return;
        String label = cases.get(test).name + "_" + clickIndex;
        if (!equal(game, expected, label)) return;
        if (!label.equals(requested)) {
            requested = label;
            StringBuilder command = new StringBuilder("inventory_check ").append(label);
            for (int slot = 0; slot < expected.length; slot++) {
                ItemStack stack = expected[slot];
                if (!stack.isEmpty()) command.append(' ').append(slot).append('/').append(BuiltInRegistries.ITEM.getKey(stack.getItem())).append('/').append(stack.getCount());
            }
            if (cases.get(test).name.startsWith("drop_")) {
                int actual = 0;
                for (var entity : game.level.entitiesForRendering()) if (entity instanceof ItemEntity item) actual += item.getItem().getCount();
                if (actual != dropped) {
                    failed(game, label + "_dropped_items_expected_" + dropped + "_actual_" + actual);
                    return;
                }
                command.append(" drops/").append(dropped);
            }
            client.send(command.toString());
        }
    }

    private boolean equal(Minecraft game, ItemStack[] wanted, String label) {
        ItemStack[] actual = snapshot(game);
        for (int slot = 0; slot < wanted.length; slot++) {
            if (!ItemStack.matches(wanted[slot], actual[slot])) {
                client.event("inventory_mismatch", "case", label, "slot", slot, "expected", wanted[slot].toString(), "actual", actual[slot].toString());
                failed(game, label + "_slot_" + slot);
                return false;
            }
        }
        return true;
    }

    private void failed(Minecraft game, String label) {
        pendingFailure = label;
        if (!client.screenshot(label).done()) return;
        pendingFailure = null;
        failures.add(label);
        test++;
        clickIndex = 0;
        phase = Phase.CLOSE_MENU;
    }

    private static ItemStack[] snapshot(Minecraft game) {
        ItemStack[] result = new ItemStack[47];
        for (int slot = 0; slot < 46; slot++) result[slot] = game.player.inventoryMenu.getSlot(slot).getItem().copy();
        result[46] = game.player.containerMenu.getCarried().copy();
        return result;
    }

    private static boolean matchesSetup(Minecraft game, String setup) {
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
            ItemStack stack = game.player.inventoryMenu.getSlot(slot).getItem();
            if (stack.getCount() != count) return false;
            if (!stack.isEmpty() && !BuiltInRegistries.ITEM.getKey(stack.getItem()).toString().equals(name)) return false;
        }
        return true;
    }

    private static Click pick(int slot, int button) { return click(slot, button, ClickType.PICKUP); }
    private static Click drag(int slot, int button) { return click(slot, button, ClickType.QUICK_CRAFT); }
    private static Click click(int slot, int button, ClickType type) { return new Click(slot, button, type); }

}
