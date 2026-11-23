package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.network.protocol.game.ServerboundSetCarriedItemPacket;
import net.minecraft.network.protocol.game.ServerboundPlayerActionPacket;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.block.Blocks;

/// Nothing is refused for want of room: drops, mining and closing a full inventory all go
/// through, with item caches far smaller than what the server holds.
final class ItemCapacityFixture extends Fixture {
    private static final int BREAD_COUNT = 17;
    private static final BlockPos BLOCK = new BlockPos(1, 65, 1);
    /// Ticks to hold the dig: an iron pickaxe breaks stone in 8.
    private static final int MINING_TICKS = 20;
    private enum Phase { SETUP, DROP, DROPPED, MINING, MINED, CLOSE_READY, CLOSED, VERIFIED }
    private Phase phase = Phase.SETUP;
    private int mining_ticks = 0;

    ItemCapacityFixture(Recorder r) { super(r); }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || missing != 0 || game.player == null) return;
        var inventory = game.player.getInventory();
        if (phase == Phase.SETUP) {
            client.send("capacity_setup");
            phase = Phase.DROP;
        } else if (phase == Phase.DROP && client.received("capacity placed") && inventory.getItem(0).getCount() == BREAD_COUNT) {
            game.player.drop(true);
            if (r.scenario.endsWith("creative"))
                game.gameMode.handleCreativeModeItemDrop(new net.minecraft.world.item.ItemStack(Items.BREAD, 4));
            client.fence("capacity-drop");
            phase = Phase.DROPPED;
        } else if (phase == Phase.DROPPED && client.fenced("capacity-drop")) {
            if (!inventory.getItem(0).isEmpty()) {
                client.fail("capacity_drop_refused"); return;
            }
            client.send("capacity_check_drop");
            phase = Phase.MINING;
        } else if (phase == Phase.MINING) {
            if (r.scenario.endsWith("creative")) {
                if (client.received("capacity creative kept")) {
                    client.pass("drops_are_never_refused_with_tiny_item_caches");
                    phase = Phase.VERIFIED;
                }
                return;
            }
            if (!client.received("capacity drops kept")) return;
            if (mining_ticks == 0) {
                inventory.setSelectedSlot(1);
                game.getConnection().send(new ServerboundSetCarriedItemPacket(1));
                game.getConnection().send(new ServerboundPlayerActionPacket(
                    ServerboundPlayerActionPacket.Action.START_DESTROY_BLOCK, BLOCK, Direction.UP, 0));
            }
            mining_ticks += 1;
            if (mining_ticks < MINING_TICKS) return;
            game.getConnection().send(new ServerboundPlayerActionPacket(
                ServerboundPlayerActionPacket.Action.STOP_DESTROY_BLOCK, BLOCK, Direction.UP, 1));
            phase = Phase.MINED;
        } else if (phase == Phase.MINED && client.received("capacity mined kept")) {
            if (game.level.getBlockState(BLOCK).is(Blocks.STONE)) return;
            inventory.setSelectedSlot(0);
            game.getConnection().send(new ServerboundSetCarriedItemPacket(0));
            client.send("capacity_close_setup");
            phase = Phase.CLOSE_READY;
        } else if (phase == Phase.CLOSE_READY && client.received("capacity close ready")) {
            game.getConnection().send(new net.minecraft.network.protocol.game.ServerboundContainerClosePacket(0));
            client.fence("capacity-close");
            phase = Phase.CLOSED;
        } else if (phase == Phase.CLOSED && client.fenced("capacity-close")) {
            client.send("capacity_close_check");
            phase = Phase.VERIFIED;
        } else if (phase == Phase.VERIFIED && client.received("capacity close kept")) {
            client.pass("drops_mining_and_closing_are_never_refused_with_tiny_item_caches");
        }
    }
}
