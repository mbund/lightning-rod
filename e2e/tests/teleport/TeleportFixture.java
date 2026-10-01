package dev.lightningrod.e2e;

import java.nio.file.Files;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;

final class TeleportFixture extends Fixture {
    private int itemsStage;
    private java.util.concurrent.CompletableFuture<com.mojang.brigadier.suggestion.Suggestions> commandSuggestions;
    private int worldsStage;
    private long itemsTick;
    private int breakingStages;
    private boolean breakingCleared;
    private volatile boolean holdTeleport;
    private volatile net.minecraft.network.protocol.game.ServerboundAcceptTeleportationPacket heldTeleport;
    private boolean repeatedTeleport;

    TeleportFixture(Recorder r) { super(r); }

    public void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0 || client.player == null || client.level == null) return;
        if (r.tick - r.terrainTick > 900) { r.fail(client, "teleport_timeout_" + itemsStage); return; }
        var handler = client.getConnection();
        var root = handler.getCommands().getRoot();
        if (root.getChild("help") == null) return;
        boolean alice = r.peer.equals("alice");
        if ((root.getChild("tp") != null) != alice || (root.getChild("teleport") != null) != alice) {
            r.fail(client, "teleport_operator_permission"); return;
        }
        String dimension = GameApi.dimension(client).split(":", 2)[1];
        if (r.tick % 100 == 0) r.event("teleport_progress", "dimension", dimension, "players", client.level.players().size(), "stage", itemsStage);
        String[] dimensions = {"the_nether", "the_end", "overworld_two", "overworld"};
        if (!Files.exists(r.artifacts.resolve("world-isolation-done"))) {
            if (!alice) {
                if (worldsStage == 0 && Files.exists(r.artifacts.resolve("world-isolation-setup")) && client.level.getBlockState(new BlockPos(10, 64, 11)).is(net.minecraft.world.level.block.Blocks.STONE)) {
                    itemsTick = r.tick;
                    worldsStage = 1;
                }
                if (worldsStage == 1 && r.tick - itemsTick >= 10) {
                    handler.send(new net.minecraft.network.protocol.game.ServerboundPlayerActionPacket(net.minecraft.network.protocol.game.ServerboundPlayerActionPacket.Action.START_DESTROY_BLOCK, new BlockPos(10, 64, 11), net.minecraft.core.Direction.UP, 0));
                    worldsStage = 2;
                }
                if (dimension.equals("the_nether") && client.level.players().size() == 1) r.marker("world-isolation-separated");
                return;
            }
            if (worldsStage == 0 && client.level.players().size() == 2 && client.player.getInventory().getItem(0).getCount() == 17) {
                handler.sendCommand("testisolation setup");
                worldsStage = 1;
            } else if (worldsStage == 1 && r.close(client.player.getX(), 8.5, 0.01) && client.player.getInventory().getItem(1).is(net.minecraft.world.item.Items.STONE)) {
                r.marker("world-isolation-setup");
                if (breakingStages == 0) return;
                breakingCleared = false;
                handler.sendCommand("testisolation move");
                worldsStage = 2;
            } else if (worldsStage == 2 && Files.exists(r.artifacts.resolve("world-isolation-separated")) && client.level.players().size() == 1 && breakingCleared) {
                client.player.getInventory().setSelectedSlot(1);
                handler.send(new net.minecraft.network.protocol.game.ServerboundSetCarriedItemPacket(1));
                client.gameMode.useItemOn(client.player, net.minecraft.world.InteractionHand.MAIN_HAND,
                    new net.minecraft.world.phys.BlockHitResult(new net.minecraft.world.phys.Vec3(10.5, 65, 10.5), net.minecraft.core.Direction.UP, new BlockPos(10, 64, 10), false));
                itemsTick = r.tick;
                worldsStage = 3;
            } else if (worldsStage == 3 && r.tick - itemsTick >= 20) {
                if (!client.level.getBlockState(new BlockPos(10, 65, 10)).is(net.minecraft.world.level.block.Blocks.STONE) || client.player.getInventory().getItem(1).getCount() != 7) { r.fail(client, "other_world_player_blocked_placement"); return; }
                if (client.player.getInventory().getItem(0).getCount() != 17) { r.fail(client, "cross_world_item_pickup"); return; }
                for (var entity : client.level.entitiesForRendering()) if (entity instanceof net.minecraft.world.entity.item.ItemEntity) { r.fail(client, "cross_world_item_visibility"); return; }
                r.screenshot(client, "world_interactions_isolated");
                handler.sendCommand("testisolation verify");
                worldsStage = 4;
            } else if (worldsStage == 4 && r.receivedChat.contains("verify") && client.level.players().size() == 2) {
                for (var player : client.level.players()) if (player != client.player && (!player.getMainHandItem().is(net.minecraft.world.item.Items.BREAD) || player.getMainHandItem().getCount() != 17)) return;
                client.player.getInventory().setSelectedSlot(0);
                handler.send(new net.minecraft.network.protocol.game.ServerboundSetCarriedItemPacket(0));
                r.marker("world-isolation-done");
            }
            return;
        }
        if (!alice) {
            if (itemsStage == 0) { handler.sendCommand("tp alice"); itemsStage = 1; }
            if (r.receivedChat.stream().anyMatch(text -> text.startsWith("Unknown command or insufficient permission"))) r.marker("bob-not-op");
            if (client.level.players().size() == 1 && (!dimension.equals("overworld") || Files.exists(r.artifacts.resolve("bob-joined-the_end")))) r.marker("bob-alone-" + dimension);
            if (Files.exists(r.artifacts.resolve("alice-joined-" + dimension)) && client.level.players().size() == 2) {
                if (client.player.getInventory().getItem(0).getCount() != 17) { r.fail(client, "teleport_inventory_lost"); return; }
                r.marker("bob-joined-" + dimension);
                if (dimension.equals("overworld")) r.pass(client, "teleport_non_op_and_world_isolation");
            }
            return;
        }
        if (itemsStage == 0 && Files.exists(r.artifacts.resolve("bob-not-op"))) {
            var dispatcher = handler.getCommands();
            commandSuggestions = dispatcher.getCompletionSuggestions(dispatcher.parse("tp b", handler.getSuggestionsProvider()));
            itemsStage = 1;
        }
        if (itemsStage == 1 && commandSuggestions.isDone()) {
            if (!commandSuggestions.join().getList().stream().map(value -> value.getText()).toList().equals(List.of("bob"))) {
                r.fail(client, "teleport_completion_missing"); return;
            }
            holdTeleport = true;
            var channel = ((dev.lightningrod.e2e.mixin.ClientConnectionAccessor) handler.getConnection()).lightningRod$channel();
            channel.pipeline().addLast("hold-teleport-confirmation", new io.netty.channel.ChannelOutboundHandlerAdapter() {
                @Override public void write(io.netty.channel.ChannelHandlerContext context, Object message, io.netty.channel.ChannelPromise promise) throws Exception {
                    if (holdTeleport && message instanceof net.minecraft.network.protocol.game.ServerboundAcceptTeleportationPacket confirmation) {
                        heldTeleport = confirmation;
                        promise.setSuccess();
                    } else {
                        context.write(message, promise);
                    }
                }
            });
            handler.sendCommand("tp bob");
            itemsStage = 2;
        }
        if (itemsStage == 2) {
            if (r.receivedChat.stream().noneMatch(text -> text.equals("Teleported alice to bob"))) return;
            if (holdTeleport) {
                if (heldTeleport == null) return;
                if (!repeatedTeleport) {
                    heldTeleport = null;
                    handler.sendCommand("tp bob");
                    repeatedTeleport = true;
                    return;
                }
                if (r.receivedChat.stream().filter(text -> text.equals("Teleported alice to bob")).count() < 2) return;
                holdTeleport = false;
                handler.send(heldTeleport);
                r.event("command_during_pending_teleport_verified");
            }
            if (!r.close(client.player.getX(), 10.5, 0.01) || !r.close(client.player.getZ(), 10.5, 0.01) || !client.player.onGround()) return;
            itemsStage = 3;
        }
        int round = (itemsStage - 3) / 3;
        if (itemsStage < 3 || round >= dimensions.length) return;
        String destination = dimensions[round];
        int phase = (itemsStage - 3) % 3;
        if (phase == 0) {
            handler.sendCommand("testworld " + (round == 0 ? "nether" : round == 1 ? "end" : destination));
            itemsStage++;
        } else if (phase == 1 && Files.exists(r.artifacts.resolve("bob-alone-" + destination))) {
            var oldBlock = round == 0 ? net.minecraft.world.level.block.Blocks.GRASS_BLOCK : round == 1 ? net.minecraft.world.level.block.Blocks.NETHERRACK : round == 2 ? net.minecraft.world.level.block.Blocks.END_STONE : net.minecraft.world.level.block.Blocks.STONE;
            if (!client.level.getBlockState(new BlockPos(10, 64, 10)).is(oldBlock)) { r.fail(client, "block_change_crossed_worlds"); return; }
            handler.sendCommand(round == 1 ? "teleport alice bob" : "teleport bob");
            itemsStage++;
        } else if (phase == 2 && dimension.equals(destination) && client.level.players().size() == 2 && client.player.onGround()) {
            if (client.player.getInventory().getItem(0).getCount() != 17 || !r.close(client.player.getX(), 10.5, 0.01) || !r.close(client.player.getZ(), 10.5, 0.01)) {
                r.fail(client, "teleport_state_incorrect"); return;
            }
            var expectedBlock = round == 0 ? net.minecraft.world.level.block.Blocks.NETHERRACK : round == 1 ? net.minecraft.world.level.block.Blocks.END_STONE : round == 2 ? net.minecraft.world.level.block.Blocks.STONE : net.minecraft.world.level.block.Blocks.GRASS_BLOCK;
            if (!client.level.getBlockState(new BlockPos(10, 64, 10)).is(expectedBlock)) return;
            client.options.setCameraType(net.minecraft.client.CameraType.THIRD_PERSON_BACK);
            r.marker("alice-joined-" + destination);
            if (!Files.exists(r.artifacts.resolve("bob-joined-" + destination))) return;
            r.screenshot(client, "teleport_" + destination);
            itemsStage++;
            if (round == dimensions.length - 1) r.pass(client, "teleport_and_four_world_interactions_isolated");
        }
    }

    @Override public void blockBreaking(BlockPos position, int stage) {
        if (!position.equals(new BlockPos(10, 64, 11))) return;
        if (stage >= 0 && stage < 10) breakingStages |= 1 << stage;
        else breakingCleared = true;
        r.event("block_breaking", "stage", stage);
    }
}
