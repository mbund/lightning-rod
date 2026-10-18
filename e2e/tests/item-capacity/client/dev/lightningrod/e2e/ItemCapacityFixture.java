package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.network.protocol.game.ServerboundSetCarriedItemPacket;
import net.minecraft.network.protocol.game.ServerboundPlayerActionPacket;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.block.Blocks;

final class ItemCapacityFixture extends Fixture {
    private static final int BREAD_COUNT = 17;
    private static final BlockPos BLOCK = new BlockPos(1, 65, 1);
    private enum Phase {
        SETUP, DROP, DROP_REJECTED, MINING_REJECTED,
        UNCHANGED, FREE_SLOT, DROP_ACCEPTED, RESUMED,
        CLOSE_READY, CLOSE_REJECTED, CLOSE_VERIFIED
    }
    private Phase phase = Phase.SETUP;

    ItemCapacityFixture(Recorder r) { super(r); }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missing != 0 || game.player == null) return;
        var inventory = game.player.getInventory();
        if (phase == Phase.SETUP) {
            client.send("capacity_setup");
            phase = Phase.DROP;
        } else if (phase == Phase.DROP && client.received("capacity full") && inventory.getItem(0).getCount() == BREAD_COUNT) {
            game.player.drop(true);
            if (r.scenario.endsWith("creative"))
                game.gameMode.handleCreativeModeItemDrop(new net.minecraft.world.item.ItemStack(Items.BREAD, 4));
            client.fence("capacity-drop");
            phase = Phase.DROP_REJECTED;
        } else if (phase == Phase.DROP_REJECTED && client.fenced("capacity-drop")) {
            if (!inventory.getItem(0).is(Items.BREAD) || inventory.getItem(0).getCount() != BREAD_COUNT) {
                client.fail("capacity_inventory_not_restored"); return;
            }
            if (!r.scenario.endsWith("creative")) {
                inventory.setSelectedSlot(1);
                game.getConnection().send(new ServerboundSetCarriedItemPacket(1));
                game.getConnection().send(new ServerboundPlayerActionPacket(
                    ServerboundPlayerActionPacket.Action.START_DESTROY_BLOCK, BLOCK, Direction.UP, 0));
                game.getConnection().send(new ServerboundPlayerActionPacket(
                    ServerboundPlayerActionPacket.Action.STOP_DESTROY_BLOCK, BLOCK, Direction.UP, 1));
                phase = Phase.MINING_REJECTED;
            } else {
                client.send("capacity_check");
                phase = Phase.UNCHANGED;
            }
        } else if (phase == Phase.MINING_REJECTED) {
            if (!client.received("capacity mining rejected")) return;
            inventory.setSelectedSlot(0);
            game.getConnection().send(new ServerboundSetCarriedItemPacket(0));
            client.send("capacity_check");
            phase = Phase.UNCHANGED;
        } else if (phase == Phase.UNCHANGED && client.received("capacity unchanged")) {
            if (!game.level.getBlockState(BLOCK).is(Blocks.STONE)) return;
            if (!client.screenshot("capacity_rejected_without_mutation").done()) return;
            client.send("capacity_free");
            phase = Phase.FREE_SLOT;
        } else if (phase == Phase.FREE_SLOT && client.received("capacity freed")) {
            game.player.drop(false);
            phase = Phase.DROP_ACCEPTED;
        } else if (phase == Phase.DROP_ACCEPTED && inventory.getItem(0).getCount() == BREAD_COUNT - 1) {
            client.send("capacity_verify");
            phase = Phase.RESUMED;
        } else if (phase == Phase.RESUMED && client.received("capacity resumed")) {
            if (r.scenario.endsWith("creative")) {
                client.pass("capacity_rejection_and_recovery_preserve_inventory_and_world");
            } else {
                client.send("capacity_close_setup");
                phase = Phase.CLOSE_READY;
            }
        } else if (phase == Phase.CLOSE_READY && client.received("capacity close ready")) {
            game.getConnection().send(new net.minecraft.network.protocol.game.ServerboundContainerClosePacket(0));
            client.fence("capacity-close");
            phase = Phase.CLOSE_REJECTED;
        } else if (phase == Phase.CLOSE_REJECTED && client.fenced("capacity-close")) {
            client.send("capacity_close_check");
            phase = Phase.CLOSE_VERIFIED;
        } else if (phase == Phase.CLOSE_VERIFIED && client.received("capacity close preserved")) {
            for (int slot = 1; slot <= 4; slot++)
                if (game.player.containerMenu.getSlot(slot).getItem().getCount() != 1) {
                    client.fail("capacity_close_slot_lost"); return;
                }
            if (game.player.containerMenu.getCarried().getCount() != 1) {
                client.fail("capacity_close_cursor_lost"); return;
            }
            client.pass("capacity_rejection_batch_atomicity_and_recovery_preserve_items");
        }
    }
}
