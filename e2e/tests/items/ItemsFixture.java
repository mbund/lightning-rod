package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.network.packet.c2s.play.PlayerMoveC2SPacket;
import net.minecraft.client.MinecraftClient;
import net.minecraft.util.math.BlockPos;

final class ItemsFixture extends Fixture {
    private int itemsStage;
    private long itemsTick;
    private int mergedEntity = -1;
    private int breakingStages;
    private boolean breakingCleared;
    private long miningStarted;

    ItemsFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }

    public void tick(MinecraftClient client, int loaded, int missing) {
        if (r.terrainTick < 0 || r.missingChunks(client, 2) != 0) return;
        if (r.tick - r.terrainTick > 400) { r.fail(client, "items_timeout_stage_" + itemsStage); return; }
        if (itemsStage == 0) {
            client.player.setPosition(r.peer.equals("alice") ? 0.5 : 8.5, 65, 3.5);
            client.player.setYaw(r.peer.equals("alice") ? -125 : 125);
            client.player.setPitch(10);
            r.marker(r.peer + ".items-ready");
            itemsStage = 1;
        }
        for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".items-ready"))) return;
        if (itemsStage == 1) {
            if (r.peer.equals("alice")) client.getNetworkHandler().sendChatCommand("items_create");
            itemsStage = 2;
        }
        int count = 0;
        int total = 0;
        double highest = 0;
        net.minecraft.entity.ItemEntity last = null;
        for (var entity : client.world.getEntities()) if (entity instanceof net.minecraft.entity.ItemEntity item && !item.isRemoved()) {
            count++;
            total += item.getStack().getCount();
            highest = Math.max(highest, item.getY());
            last = item;
            if (itemsStage < 8 && !item.getStack().isOf(net.minecraft.item.Items.BREAD)) { r.fail(client, "wrong_item_type"); return; }
        }
        if (itemsStage == 2 && count > 0 && total == 17 && highest > 65.5) {
            r.event("items_falling", "entities", count, "total", total, "y", highest);
            r.screenshot(client, "items_falling");
            itemsStage = 3;
        }
        if (itemsStage == 3 && count == 1 && total == 17 && Math.abs(highest - 65) < 0.01) {
            mergedEntity = last.getId();
            r.event("items_merged", "entity", mergedEntity, "count", total, "y", highest);
            r.screenshot(client, "items_merged");
            r.marker(r.peer + ".items-merged");
            itemsStage = 4;
            itemsTick = r.tick;
        }
        if (itemsStage == 4) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".items-merged"))) return;
            if (r.tick - itemsTick < 10) return;
            if (r.peer.equals("alice")) {
                client.player.setPosition(4.5, 65, 0.5);
                client.getNetworkHandler().sendPacket(new PlayerMoveC2SPacket.PositionAndOnGround(4.5, 65, 0.5, true, false));
            }
            itemsStage = 5;
        }
        if (itemsStage == 5 && count == 0) {
            int held = client.player.getInventory().count(net.minecraft.item.Items.BREAD);
            if (held != (r.peer.equals("alice") ? 17 : 0)) return;
            r.marker(r.peer + ".items-collected");
            r.screenshot(client, "items_collected");
            itemsStage = 6;
        }
        if (itemsStage == 6) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".items-collected"))) return;
            client.getNetworkHandler().sendChatCommand("items_check");
            itemsStage = 7;
        }
        if (itemsStage == 7 && r.receivedChat.contains("Items verified")) {
            if (r.peer.equals("alice")) client.getNetworkHandler().sendChatCommand("items_mine_setup");
            itemsStage = 8;
        }
        var first = new BlockPos(4, 65, -2);
        var second = new BlockPos(5, 65, -2);
        if (itemsStage == 8 && client.world.getBlockState(first).isOf(net.minecraft.block.Blocks.STONE)) {
            if (r.peer.equals("alice")) {
                org.lwjgl.glfw.GLFW.glfwFocusWindow(client.getWindow().getHandle());
                client.mouse.lockCursor();
                if (!client.mouse.isCursorLocked()) return;
                client.options.attackKey.setPressed(false);
            }
            r.marker(r.peer + ".mining-ready");
            itemsStage = 9;
            return;
        }
        if (itemsStage == 9) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".mining-ready"))) return;
            if (miningStarted == 0) miningStarted = r.tick;
            if (client.world.getBlockState(first).isAir()) {
                client.options.attackKey.setPressed(false);
                if (r.peer.equals("alice") && r.tick - miningStarted < 145) { r.fail(client, "hand_mining_too_fast"); return; }
                if (count != 0) { r.fail(client, "wrong_tool_dropped_stone"); return; }
                if (r.peer.equals("bob") && (breakingStages != 1023 || !breakingCleared)) return;
                r.event("hand_mining_verified", "ticks", r.tick - miningStarted, "stages", breakingStages);
                r.marker(r.peer + ".hand-mined");
                itemsStage = 10;
            } else if (r.peer.equals("alice")) {
                client.player.getInventory().setSelectedSlot(0);
                client.player.setYaw(180);
                client.player.setPitch((float)Math.toDegrees(Math.atan2(client.player.getEyeY() - 65.5, 2)));
                client.options.attackKey.setPressed(true);
            }
        }
        if (itemsStage == 10) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".hand-mined"))) return;
            if (r.peer.equals("alice")) {
                client.player.getInventory().setSelectedSlot(1);
                client.interactionManager.cancelBlockBreaking();
            }
            itemsStage = 11;
            miningStarted = r.tick;
        }
        if (itemsStage == 11) {
            if (!client.world.getBlockState(second).isAir() && r.peer.equals("alice")) {
                client.player.setYaw((float)Math.toDegrees(Math.atan2(-1, -2)));
                client.player.setPitch((float)Math.toDegrees(Math.atan2(client.player.getEyeY() - 65.5, Math.sqrt(5))));
                client.options.attackKey.setPressed(true);
            }
            if (client.world.getBlockState(second).isAir() && count == 1 && last.getStack().isOf(net.minecraft.item.Items.COBBLESTONE)) {
                client.options.attackKey.setPressed(false);
                if (r.tick - miningStarted > 30) { r.fail(client, "pickaxe_mining_too_slow"); return; }
                if (r.peer.equals("alice") && client.player.getInventory().getStack(1).getDamage() != 1) return;
                r.event("pickaxe_mining_verified", "ticks", r.tick - miningStarted, "drop_count", last.getStack().getCount());
                r.screenshot(client, "mining_drop");
                r.marker(r.peer + ".mining-done");
                itemsStage = 12;
            }
        }
        if (itemsStage == 12) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".mining-done"))) return;
            r.pass(client, "items_and_tool_aware_mining_synchronized");
        }
    }

    @Override public void blockBreaking(BlockPos position, int stage) {
        if (!position.equals(new BlockPos(4, 65, -2))) return;
        if (stage >= 0 && stage < 10) breakingStages |= 1 << stage;
        else breakingCleared = true;
        r.event("block_breaking", "stage", stage);
    }
}
