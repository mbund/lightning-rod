package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;

final class CreativeFixture extends Fixture {
    private long miningStarted;
    private int itemsStage;
    private long itemsTick;

    CreativeFixture(Recorder r) { super(r); }

    public void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0 || r.missingChunks(client, 2) != 0) return;
        if (r.tick - r.terrainTick > 400) { r.fail(client, "creative_timeout_stage_" + itemsStage); return; }
        boolean alice = r.peer.equals("alice");
        if (itemsStage == 0) {
            client.player.setPos(alice ? 0.5 : 8.5, 65, 3.5);
            client.player.setYRot(alice ? -90 : 90);
            client.player.setXRot(20);
            r.marker(r.peer + ".creative-ready");
            itemsStage = 1;
        }
        for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-ready"))) return;
        if (itemsStage == 1) {
            if (alice) {
                var stack = new net.minecraft.world.item.ItemStack(net.minecraft.world.item.Items.STONE, 8);
                client.player.getInventory().setSelectedSlot(0);
                client.player.getInventory().setItem(0, stack);
                client.gameMode.handleCreativeModeItemAdd(stack, 36);
            }
            itemsStage = 2;
        }
        net.minecraft.world.entity.player.Player subject = null;
        for (var player : client.level.players()) if (player.getName().getString().equals("alice")) subject = player;
        if (subject == null) return;
        if (itemsStage == 2 && subject.getMainHandItem().is(net.minecraft.world.item.Items.STONE) && subject.getMainHandItem().getCount() == 8) {
            r.marker(r.peer + ".creative-held");
            r.screenshot(client, "creative_equipment");
            itemsStage = 3;
        }
        BlockPos placed = new BlockPos(3, 65, 1);
        if (itemsStage == 3) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-held"))) return;
            if (alice) client.gameMode.useItemOn(client.player, net.minecraft.world.InteractionHand.MAIN_HAND,
                new net.minecraft.world.phys.BlockHitResult(new net.minecraft.world.phys.Vec3(3.5, 65, 1.5), net.minecraft.core.Direction.UP, placed.below(), false));
            itemsStage = 4;
        }
        if (itemsStage == 4 && client.level.getBlockState(placed).is(net.minecraft.world.level.block.Blocks.STONE)) {
            r.marker(r.peer + ".creative-placed");
            miningStarted = r.tick;
            itemsStage = 5;
        }
        if (itemsStage == 5) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-placed"))) return;
            if (r.tick - miningStarted < 10) return;
            if (!client.level.getBlockState(placed).is(net.minecraft.world.level.block.Blocks.STONE)) { r.fail(client, "creative_placement_reverted"); return; }
            r.screenshot(client, "creative_block");
            if (alice) client.player.drop(false);
            itemsStage = 6;
        }
        int stone = 0;
        int bread = 0;
        for (var entity : client.level.entitiesForRendering()) if (entity instanceof net.minecraft.world.entity.item.ItemEntity item) {
            if (item.getItem().is(net.minecraft.world.item.Items.STONE)) stone += item.getItem().getCount();
            if (item.getItem().is(net.minecraft.world.item.Items.BREAD)) bread += item.getItem().getCount();
        }
        if (itemsStage == 6 && stone == 1 && subject.getMainHandItem().getCount() == 7) {
            r.marker(r.peer + ".creative-dropped-one");
            itemsStage = 7;
        }
        if (itemsStage == 7) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-dropped-one"))) return;
            if (alice) client.player.drop(true);
            itemsStage = 8;
        }
        if (itemsStage == 8 && stone == 8 && subject.getMainHandItem().isEmpty()) {
            r.marker(r.peer + ".creative-dropped-stack");
            itemsStage = 9;
        }
        if (itemsStage == 9) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-dropped-stack"))) return;
            if (alice) client.gameMode.handleCreativeModeItemDrop(new net.minecraft.world.item.ItemStack(net.minecraft.world.item.Items.BREAD, 4));
            itemsStage = 10;
        }
        if (itemsStage == 10 && bread == 4 && stone == 8) {
            r.event("creative_verified", "stone_dropped", stone, "bread_dropped", bread, "held_empty", subject.getMainHandItem().isEmpty());
            r.screenshot(client, "creative_drops");
            r.marker(r.peer + ".creative-done");
            itemsStage = 11;
        }
        if (itemsStage == 11) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-done"))) return;
            if (alice) client.gameMode.startDestroyBlock(placed, net.minecraft.core.Direction.UP);
            itemsStage = 12;
        }
        if (itemsStage == 12 && client.level.getBlockState(placed).isAir()) {
            r.marker(r.peer + ".creative-broken");
            itemsStage = 13;
        }
        if (itemsStage == 13) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-broken"))) return;
            r.pass(client, "creative_inventory_placement_equipment_and_drops_synchronized");
        }
    }

}
