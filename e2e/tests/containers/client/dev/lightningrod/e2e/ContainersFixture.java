package dev.lightningrod.e2e;

import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.network.protocol.game.ServerboundMovePlayerPacket;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.ChestBlock;
import net.minecraft.world.level.block.entity.ChestBlockEntity;
import net.minecraft.world.level.block.entity.FurnaceBlockEntity;
import net.minecraft.world.level.block.FurnaceBlock;
import net.minecraft.world.level.block.state.properties.ChestType;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;

final class ContainersFixture extends Fixture {
    private static final int BREAD_COUNT = 17;
    private static final BlockPos CHEST = new BlockPos(2, 65, 0);
    private static final BlockPos FURNACE = new BlockPos(4, 65, 0);
    private final boolean chests;
    private final boolean furnace;
    private final boolean actor;
    private String phase = "waiting";
    private int readyJoin;
    private boolean reloaded;
    private int furnaceExperience;
    private long started;
    private List<Click> script = List.of();
    private int action;
    private String scriptName;
    private String afterScript;
    private boolean pendingAction;
    private record Click(int slot, int button, ClickType type) {}

    ContainersFixture(Recorder r) {
        super(r);
        chests = r.scenario.startsWith("chests");
        furnace = r.scenario.startsWith("furnace");
        actor = !chests || r.peer.equals("alice");
    }

    @Override boolean encrypted() { return true; }

    @Override boolean prepare(Minecraft game) {
        game.getTutorial().setStep(net.minecraft.client.tutorial.TutorialSteps.NONE);
        return true;
    }

    @Override void message(String text) {
        if (text.startsWith("fence ")) return;
        switch (text) {
            case "setup" -> phase = actor ? "place" : "waiting_deposit";
            case "placed" -> phase = chests ? "chest_open" : furnace ? "furnace_open" : "inventory_open";
            case "deposited" -> phase = actor ? "close_chest" : "chest_open";
            case "reloaded" -> { reloaded = true; phase = chests ? "chest_open" : furnace ? "furnace_open" : "crafting_reloaded"; }
            case "cooked" -> phase = "take_output";
            case "verified" -> phase = "verified";
            case "complete" -> phase = "complete";
            default -> client.fail("unexpected_container_message_" + text);
        }
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || r.terrainTick < 0) return;
        if (started == 0) started = System.nanoTime();
        if (System.nanoTime() - started > 120_000_000_000L) {
            client.fail("containers_timeout_" + phase + "_slots_" + game.player.containerMenu.slots.size() + "_actions_" + action);
            return;
        }
        if (readyJoin != r.joins && game.level.hasChunkAt(FURNACE)) {
            readyJoin = r.joins;
            script = List.of();
            client.send("ready");
            return;
        }
        if (!script.isEmpty()) {
            runScript(game);
            return;
        }
        switch (phase) {
            case "place" -> {
                Item item = chests ? Items.CHEST : furnace ? Items.FURNACE : Items.CRAFTING_TABLE;
                if (game.player.getInventory().getItem(0).getItem() != item) return;
                if (!close(game.player.getY(), 65, 0.01)) return;
                place(game, chests ? CHEST : FURNACE, furnace ? 90 : 0);
                phase = chests ? "place_second" : "placed_wait";
            }
            case "place_second" -> {
                if (!game.level.getBlockState(CHEST).is(Blocks.CHEST)) return;
                place(game, CHEST.east(), 0);
                phase = "placed_wait";
            }
            case "placed_wait" -> {
                if (chests) {
                    var state = game.level.getBlockState(CHEST);
                    if (!state.is(Blocks.CHEST) || state.getValue(ChestBlock.TYPE) == ChestType.SINGLE) return;
                    if (state.getValue(ChestBlock.FACING) != Direction.NORTH) { client.fail("chest_facing"); return; }
                } else if (furnace) {
                    var state = game.level.getBlockState(FURNACE);
                    if (!state.is(Blocks.FURNACE)) return;
                    if (state.getValue(FurnaceBlock.FACING) != Direction.EAST) { client.fail("furnace_facing"); return; }
                } else if (!game.level.getBlockState(FURNACE).is(Blocks.CRAFTING_TABLE)) return;
                client.send("placed");
                phase = "waiting_placed";
            }
            case "chest_open" -> {
                if (!game.level.getBlockState(CHEST).is(Blocks.CHEST) || !(game.level.getBlockEntity(CHEST) instanceof ChestBlockEntity)) return;
                use(game, CHEST);
                phase = "chest_menu";
            }
            case "chest_menu" -> {
                if (game.player.containerMenu.slots.size() != 90) return;
                if (!(game.level.getBlockEntity(CHEST) instanceof ChestBlockEntity chest) || chest.getOpenNess(0) < 0.9f) return;
                if (actor && !reloaded) {
                    int source = find(game, Items.BREAD);
                    if (source < 54) return;
                    start("deposit", List.of(new Click(source, 0, ClickType.QUICK_MOVE)), "deposited_wait");
                } else {
                    if (!stack(game, 0, Items.BREAD, BREAD_COUNT)) return;
                    if (!client.screenshot(reloaded ? "chest_after_reload" : "shared_double_chest").done()) return;
                    client.send("chest_checked");
                    phase = "waiting_reload";
                }
            }
            case "deposited_wait" -> {
                if (!stack(game, 0, Items.BREAD, BREAD_COUNT)) return;
                if (!client.screenshot("double_chest_deposit").done()) return;
                client.send("deposited");
                phase = "waiting_deposit";
            }
            case "close_chest" -> { game.player.closeContainer(); phase = "waiting_reload"; }
            case "furnace_open" -> {
                if (!game.level.getBlockState(FURNACE).is(Blocks.FURNACE) || !(game.level.getBlockEntity(FURNACE) instanceof FurnaceBlockEntity)) return;
                use(game, FURNACE);
                phase = "furnace_menu";
            }
            case "furnace_menu" -> {
                if (game.player.containerMenu.slots.size() != 39) return;
                if (!reloaded) {
                    int source = find(game, Items.RAW_IRON);
                    int fuel = find(game, Items.COAL);
                    if (source < 3 || fuel < 3) return;
                    start("fuel", List.of(new Click(source, 0, ClickType.QUICK_MOVE), new Click(fuel, 0, ClickType.QUICK_MOVE)), "burning");
                } else phase = "cooking";
            }
            case "burning" -> {
                if (!stack(game, 0, Items.RAW_IRON, 2) || !game.level.getBlockState(FURNACE).getValue(FurnaceBlock.LIT)) return;
                if (game.level.getBrightness(LightLayer.BLOCK, FURNACE) != 13) return;
                if (!client.screenshot("burning_furnace").done()) return;
                client.send("started");
                phase = "waiting_reload";
            }
            case "cooking" -> {
                if (game.player.totalExperience != 0) { client.fail("furnace_experience_before_extraction"); return; }
                if (!stack(game, 2, Items.IRON_INGOT, 2)) return;
                if (game.level.getBrightness(LightLayer.BLOCK, FURNACE) != 13) return;
                if (!client.screenshot("smelted_after_reload").done()) return;
                client.send("cooked");
                phase = "waiting_cooked";
            }
            case "take_output" -> start("take", List.of(new Click(2, 0, ClickType.QUICK_MOVE)), "output_taken");
            case "output_taken" -> {
                if (!game.player.containerMenu.getSlot(2).getItem().isEmpty()) return;
                game.player.closeContainer();
                client.fence("output_closed");
                phase = "output_closed";
            }
            case "output_closed" -> {
                if (!client.fenced("output_closed") || game.player.totalExperience == 0) return;
                furnaceExperience = game.player.totalExperience;
                if (furnaceExperience < 1 || furnaceExperience > 2) { client.fail("furnace_experience_amount"); return; }
                client.send("taken");
                phase = "waiting_reload";
            }
            case "inventory_open" -> {
                GuiApi.screen(game, new InventoryScreen(game.player));
                start("inventory_grid", List.of(new Click(37, 0, ClickType.PICKUP), new Click(1, 0, ClickType.PICKUP)), "inventory_result");
            }
            case "inventory_result" -> {
                if (!stack(game, 0, Items.OAK_PLANKS, 4)) return;
                if (!client.screenshot("inventory_crafting").done()) return;
                start("inventory_output", List.of(new Click(0, 0, ClickType.PICKUP), new Click(9, 0, ClickType.PICKUP)), "table_open");
            }
            case "table_open" -> {
                game.player.closeContainer();
                use(game, FURNACE);
                phase = "table_menu";
            }
            case "table_menu" -> {
                if (game.player.containerMenu.slots.size() != 46 || game.player.containerMenu.containerId == 0) return;
                int source = find(game, Items.COBBLESTONE);
                if (source < 10) return;
                start("table_grid", List.of(new Click(source, 0, ClickType.PICKUP),
                    new Click(1, 1, ClickType.PICKUP), new Click(2, 1, ClickType.PICKUP), new Click(3, 1, ClickType.PICKUP),
                    new Click(4, 1, ClickType.PICKUP), new Click(6, 1, ClickType.PICKUP), new Click(7, 1, ClickType.PICKUP),
                    new Click(8, 1, ClickType.PICKUP), new Click(9, 1, ClickType.PICKUP)), "table_result");
            }
            case "table_result" -> {
                if (!stack(game, 0, Items.FURNACE, 1)) return;
                if (!client.screenshot("table_crafting").done()) return;
                start("table_output", List.of(new Click(0, 0, ClickType.QUICK_MOVE)), "transient_grid");
            }
            case "transient_grid" -> {
                int planks = find(game, Items.OAK_PLANKS);
                if (planks < 10 || game.player.getInventory().countItem(Items.FURNACE) != 1) return;
                start("transient_grid", List.of(new Click(planks, 0, ClickType.PICKUP), new Click(1, 1, ClickType.PICKUP)), "crafting_saved");
            }
            case "crafting_saved" -> {
                if (!stack(game, 1, Items.OAK_PLANKS, 1) || game.player.containerMenu.getCarried().getCount() != 3) return;
                if (!client.screenshot("crafting_cursor_before_reload").done()) return;
                client.send("crafted");
                phase = "waiting_reload";
            }
            case "crafting_reloaded" -> {
                if (game.player.getInventory().countItem(Items.OAK_PLANKS) != 4 || game.player.getInventory().countItem(Items.FURNACE) != 1) return;
                if (!game.player.containerMenu.getCarried().isEmpty()) { client.fail("crafting_cursor_not_returned"); return; }
                if (!client.screenshot("crafting_after_reload").done()) return;
                client.send("crafting_checked");
                phase = "waiting_verified";
            }
            case "complete" -> {
                if (game.player.totalExperience != furnaceExperience) return;
                if (game.player.getInventory().countItem(Items.IRON_INGOT) != 2) return;
                if (!client.screenshot("furnace_output_after_reload").done()) return;
                client.pass("furnace_fuel_cooking_light_inventory_reload_verified");
            }
            case "verified" -> client.pass(chests ? "double_chest_shared_inventory_orientation_reload_verified" : "both_crafting_grids_outputs_cursor_reload_verified");
            default -> {}
        }
    }

    private void start(String name, List<Click> clicks, String after) {
        scriptName = name;
        script = clicks;
        action = 0;
        pendingAction = false;
        afterScript = after;
    }

    private void runScript(Minecraft game) {
        String label = scriptName + "_" + readyJoin + "_" + action;
        if (pendingAction) {
            if (!client.fenced(label)) return;
            action++;
            pendingAction = false;
        }
        if (action == script.size()) {
            script = List.of();
            phase = afterScript;
            return;
        }
        Click click = script.get(action);
        GameApi.inventoryClick(game, click.slot, click.button, click.type);
        client.fence(scriptName + "_" + readyJoin + "_" + action);
        pendingAction = true;
    }

    private void place(Minecraft game, BlockPos position, float yaw) {
        game.player.getInventory().setSelectedSlot(0);
        game.player.setYRot(yaw);
        game.getConnection().send(new ServerboundMovePlayerPacket.Rot(yaw, 0, true, false));
        game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND,
            new BlockHitResult(Vec3.atBottomCenterOf(position), Direction.UP, position.below(), false));
    }

    private void use(Minecraft game, BlockPos position) {
        game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND,
            new BlockHitResult(Vec3.atCenterOf(position), Direction.UP, position, false));
    }

    private boolean stack(Minecraft game, int slot, Item item, int count) {
        var stack = game.player.containerMenu.getSlot(slot).getItem();
        return stack.is(item) && stack.getCount() == count;
    }

    private int find(Minecraft game, Item item) {
        for (int i = 0; i < game.player.containerMenu.slots.size(); i++) if (game.player.containerMenu.getSlot(i).getItem().is(item)) return i;
        return -1;
    }
}
