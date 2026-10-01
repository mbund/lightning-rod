package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.network.protocol.game.ServerboundMovePlayerPacket;

final class ItemsFixture extends Fixture {
    private int itemsStage;
    private long itemsTick;
    private int mergedEntity = -1;
    private int breakingStages;
    private boolean breakingCleared;
    private long miningStarted;
    private boolean sawMiningSwing;

    ItemsFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return !r.scenario.equals("items-plaintext"); }

    public void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0 || r.missingChunks(client, 2) != 0) return;
        if (r.tick - r.terrainTick > 600) { r.fail(client, "items_timeout_stage_" + itemsStage); return; }
        if (itemsStage == 9 && r.peer.equals("bob")) {
            for (var player : client.level.players()) {
                if (player.getName().getString().equals("alice") && player.swinging && !sawMiningSwing) {
                    sawMiningSwing = true;
                    r.event("survival_mining_swing_observed", "entity", player.getId());
                    r.screenshot(client, "survival_mining_swing");
                }
            }
        }
        if (itemsStage == 0) {
            if (missing != 0) return;
            client.player.setPos(r.peer.equals("alice") ? 0.5 : 8.5, 65, 3.5);
            client.player.setYRot(r.peer.equals("alice") ? -125 : 125);
            client.player.setXRot(10);
            r.marker(r.peer + ".items-ready");
            itemsStage = 1;
        }
        for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".items-ready"))) return;
        if (itemsStage == 1) {
            if (r.peer.equals("alice")) client.getConnection().sendCommand("items_create");
            itemsStage = 2;
        }
        int count = 0;
        int total = 0;
        double highest = 0;
        net.minecraft.world.entity.item.ItemEntity last = null;
        for (var entity : client.level.entitiesForRendering()) if (entity instanceof net.minecraft.world.entity.item.ItemEntity item && !item.isRemoved()) {
            count++;
            total += item.getItem().getCount();
            highest = Math.max(highest, item.getY());
            last = item;
            if (itemsStage < 8 && !item.getItem().is(net.minecraft.world.item.Items.BREAD)) { r.fail(client, "wrong_item_type"); return; }
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
                client.player.setPos(4.5, 65, 0.5);
                client.getConnection().send(new ServerboundMovePlayerPacket.Pos(4.5, 65, 0.5, true, false));
            }
            itemsStage = 5;
        }
        if (itemsStage == 5 && count == 0) {
            int held = client.player.getInventory().countItem(net.minecraft.world.item.Items.BREAD);
            if (held != (r.peer.equals("alice") ? 17 : 0)) return;
            r.marker(r.peer + ".items-collected");
            r.screenshot(client, "items_collected");
            itemsStage = 6;
        }
        if (itemsStage == 6) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".items-collected"))) return;
            client.getConnection().sendCommand("items_check");
            itemsStage = 7;
        }
        if (itemsStage == 7 && r.receivedChat.contains("Items verified")) {
            if (r.peer.equals("alice")) client.getConnection().sendCommand("items_mine_setup");
            itemsStage = 8;
        }
        var first = new BlockPos(4, 65, -2);
        var second = new BlockPos(5, 65, -2);
        if (itemsStage == 8 && client.level.getBlockState(first).is(net.minecraft.world.level.block.Blocks.STONE)) {
            if (r.peer.equals("alice")) {
                org.lwjgl.glfw.GLFW.glfwFocusWindow(ClientApi.window(client));
                client.mouseHandler.grabMouse();
                if (!client.mouseHandler.isMouseGrabbed()) return;
                client.options.keyAttack.setDown(false);
            }
            r.marker(r.peer + ".mining-ready");
            itemsStage = 9;
            return;
        }
        if (itemsStage == 9) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".mining-ready"))) return;
            if (miningStarted == 0) miningStarted = r.tick;
            if (client.level.getBlockState(first).isAir()) {
                client.options.keyAttack.setDown(false);
                if (r.peer.equals("alice") && r.tick - miningStarted < 145) { r.fail(client, "hand_mining_too_fast"); return; }
                if (count != 0) { r.fail(client, "wrong_tool_dropped_stone"); return; }
                if (r.peer.equals("bob") && !sawMiningSwing) { r.fail(client, "survival_mining_arm_did_not_swing"); return; }
                if (r.peer.equals("bob") && (breakingStages != 1023 || !breakingCleared)) return;
                r.event("hand_mining_verified", "ticks", r.tick - miningStarted, "stages", breakingStages);
                r.marker(r.peer + ".hand-mined");
                itemsStage = 10;
            } else if (r.peer.equals("alice")) {
                client.player.getInventory().setSelectedSlot(0);
                client.player.setYRot(180);
                client.player.setXRot((float)Math.toDegrees(Math.atan2(client.player.getEyeY() - 65.5, 2)));
                client.options.keyAttack.setDown(true);
            }
        }
        if (itemsStage == 10) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".hand-mined"))) return;
            if (r.peer.equals("alice")) {
                client.player.getInventory().setSelectedSlot(1);
                client.gameMode.stopDestroyBlock();
            }
            itemsStage = 11;
            miningStarted = r.tick;
        }
        if (itemsStage == 11) {
            if (!client.level.getBlockState(second).isAir() && r.peer.equals("alice")) {
                client.player.setYRot((float)Math.toDegrees(Math.atan2(-1, -2)));
                client.player.setXRot((float)Math.toDegrees(Math.atan2(client.player.getEyeY() - 65.5, Math.sqrt(5))));
                client.options.keyAttack.setDown(true);
            }
            if (client.level.getBlockState(second).isAir() && count == 1 && last.getItem().is(net.minecraft.world.item.Items.COBBLESTONE)) {
                client.options.keyAttack.setDown(false);
                if (r.tick - miningStarted > 30) { r.fail(client, "pickaxe_mining_too_slow"); return; }
                if (r.peer.equals("alice") && client.player.getInventory().getItem(1).getDamageValue() != 1) return;
                r.event("pickaxe_mining_verified", "ticks", r.tick - miningStarted, "drop_count", last.getItem().getCount());
                r.screenshot(client, "mining_drop");
                r.marker(r.peer + ".mining-done");
                itemsStage = 12;
            }
        }
        if (itemsStage == 12) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".mining-done"))) return;
            if (r.peer.equals("alice")) client.getConnection().sendCommand("items_place_setup");
            itemsStage = 13;
        }
        var placed = new BlockPos(3, 65, -1);
        if (itemsStage == 13) {
            if (r.peer.equals("alice")) {
                int slot = -1;
                for (int i = 0; i < 9; i++) if (client.player.getInventory().getItem(i).is(net.minecraft.world.item.Items.DIRT)) slot = i;
                if (slot < 0) return;
                client.player.getInventory().setSelectedSlot(slot);
                client.gameMode.useItemOn(client.player, net.minecraft.world.InteractionHand.MAIN_HAND,
                    new net.minecraft.world.phys.BlockHitResult(new net.minecraft.world.phys.Vec3(3.5, 65, -0.5), net.minecraft.core.Direction.UP, placed.below(), false));
            }
            itemsStage = 14;
            itemsTick = r.tick;
        }
        if (itemsStage == 14 && client.level.getBlockState(placed).is(net.minecraft.world.level.block.Blocks.DIRT)) {
            if (r.tick - itemsTick < 20) return;
            if (r.peer.equals("alice") && client.player.getInventory().countItem(net.minecraft.world.item.Items.DIRT) != 7) return;
            r.screenshot(client, "survival_block_placed");
            r.marker(r.peer + ".survival-placed");
            itemsStage = 15;
        }
        if (itemsStage == 15) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".survival-placed"))) return;
            if (r.peer.equals("alice")) client.getConnection().sendCommand("items_reload");
            itemsStage = 16;
            itemsTick = -1;
        }
        if (itemsStage == 16 && r.joins == 2 && client.level.players().size() == 2) {
            if (!client.level.getBlockState(placed).is(net.minecraft.world.level.block.Blocks.DIRT)) {
                r.fail(client, "survival_placement_lost_after_reload"); return;
            }
            if (!client.level.getBlockState(first).isAir() || !client.level.getBlockState(second).isAir()) {
                r.fail(client, "survival_mining_lost_after_reload"); return;
            }
            if (r.peer.equals("alice") && client.player.getInventory().countItem(net.minecraft.world.item.Items.DIRT) != 7) return;
            if (itemsTick < 0) {
                itemsTick = r.tick;
                double dx = 3.5 - client.player.getX();
                double dz = -0.5 - client.player.getZ();
                client.player.setYRot((float)Math.toDegrees(Math.atan2(-dx, dz)));
                client.player.setXRot((float)Math.toDegrees(Math.atan2(client.player.getEyeY() - 65.5, Math.hypot(dx, dz))));
            }
            if (r.tick - itemsTick < 20) return;
            r.screenshot(client, "survival_blocks_after_reload");
            r.marker(r.peer + ".survival-restored");
            itemsStage = 17;
        }
        if (itemsStage == 17) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".survival-restored"))) return;
            r.pass(client, "survival_mining_swing_placement_and_reload_verified");
        }
    }

    @Override public void blockBreaking(BlockPos position, int stage) {
        if (!position.equals(new BlockPos(4, 65, -2))) return;
        if (stage >= 0 && stage < 10) breakingStages |= 1 << stage;
        else breakingCleared = true;
        r.event("block_breaking", "stage", stage);
    }
}
