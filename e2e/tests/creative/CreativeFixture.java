package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.MinecraftClient;
import net.minecraft.util.math.BlockPos;

final class CreativeFixture extends Fixture {
    private long miningStarted;
    private int itemsStage;
    private long itemsTick;

    CreativeFixture(Recorder r) { super(r); }

    public void tick(MinecraftClient client, int loaded, int missing) {
        if (r.terrainTick < 0 || r.missingChunks(client, 2) != 0) return;
        if (r.tick - r.terrainTick > 400) { r.fail(client, "creative_timeout_stage_" + itemsStage); return; }
        boolean alice = r.peer.equals("alice");
        if (itemsStage == 0) {
            client.player.setPosition(alice ? 0.5 : 8.5, 65, 3.5);
            client.player.setYaw(alice ? -90 : 90);
            client.player.setPitch(20);
            r.marker(r.peer + ".creative-ready");
            itemsStage = 1;
        }
        for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-ready"))) return;
        if (itemsStage == 1) {
            if (alice) {
                var stack = new net.minecraft.item.ItemStack(net.minecraft.item.Items.STONE, 8);
                client.player.getInventory().setSelectedSlot(0);
                client.player.getInventory().setStack(0, stack);
                client.interactionManager.clickCreativeStack(stack, 36);
            }
            itemsStage = 2;
        }
        net.minecraft.entity.player.PlayerEntity subject = null;
        for (var player : client.world.getPlayers()) if (player.getName().getString().equals("alice")) subject = player;
        if (subject == null) return;
        if (itemsStage == 2 && subject.getMainHandStack().isOf(net.minecraft.item.Items.STONE) && subject.getMainHandStack().getCount() == 8) {
            r.marker(r.peer + ".creative-held");
            r.screenshot(client, "creative_equipment");
            itemsStage = 3;
        }
        BlockPos placed = new BlockPos(3, 65, 1);
        if (itemsStage == 3) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-held"))) return;
            if (alice) client.interactionManager.interactBlock(client.player, net.minecraft.util.Hand.MAIN_HAND,
                new net.minecraft.util.hit.BlockHitResult(new net.minecraft.util.math.Vec3d(3.5, 65, 1.5), net.minecraft.util.math.Direction.UP, placed.down(), false));
            itemsStage = 4;
        }
        if (itemsStage == 4 && client.world.getBlockState(placed).isOf(net.minecraft.block.Blocks.STONE)) {
            r.marker(r.peer + ".creative-placed");
            miningStarted = r.tick;
            itemsStage = 5;
        }
        if (itemsStage == 5) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-placed"))) return;
            if (r.tick - miningStarted < 10) return;
            if (!client.world.getBlockState(placed).isOf(net.minecraft.block.Blocks.STONE)) { r.fail(client, "creative_placement_reverted"); return; }
            r.screenshot(client, "creative_block");
            if (alice) client.player.dropSelectedItem(false);
            itemsStage = 6;
        }
        int stone = 0;
        int bread = 0;
        for (var entity : client.world.getEntities()) if (entity instanceof net.minecraft.entity.ItemEntity item) {
            if (item.getStack().isOf(net.minecraft.item.Items.STONE)) stone += item.getStack().getCount();
            if (item.getStack().isOf(net.minecraft.item.Items.BREAD)) bread += item.getStack().getCount();
        }
        if (itemsStage == 6 && stone == 1 && subject.getMainHandStack().getCount() == 7) {
            r.marker(r.peer + ".creative-dropped-one");
            itemsStage = 7;
        }
        if (itemsStage == 7) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-dropped-one"))) return;
            if (alice) client.player.dropSelectedItem(true);
            itemsStage = 8;
        }
        if (itemsStage == 8 && stone == 8 && subject.getMainHandStack().isEmpty()) {
            r.marker(r.peer + ".creative-dropped-stack");
            itemsStage = 9;
        }
        if (itemsStage == 9) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-dropped-stack"))) return;
            if (alice) client.interactionManager.dropCreativeStack(new net.minecraft.item.ItemStack(net.minecraft.item.Items.BREAD, 4));
            itemsStage = 10;
        }
        if (itemsStage == 10 && bread == 4 && stone == 8) {
            r.event("creative_verified", "stone_dropped", stone, "bread_dropped", bread, "held_empty", subject.getMainHandStack().isEmpty());
            r.screenshot(client, "creative_drops");
            r.marker(r.peer + ".creative-done");
            itemsStage = 11;
        }
        if (itemsStage == 11) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-done"))) return;
            if (alice) client.interactionManager.attackBlock(placed, net.minecraft.util.math.Direction.UP);
            itemsStage = 12;
        }
        if (itemsStage == 12 && client.world.getBlockState(placed).isAir()) {
            r.marker(r.peer + ".creative-broken");
            itemsStage = 13;
        }
        if (itemsStage == 13) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".creative-broken"))) return;
            r.pass(client, "creative_inventory_placement_equipment_and_drops_synchronized");
        }
    }

}
