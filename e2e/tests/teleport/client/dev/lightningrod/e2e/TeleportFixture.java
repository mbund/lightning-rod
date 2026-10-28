package dev.lightningrod.e2e;

import com.mojang.brigadier.suggestion.Suggestions;
import dev.lightningrod.e2e.mixin.ClientConnectionAccessor;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelOutboundHandlerAdapter;
import io.netty.channel.ChannelPromise;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import net.minecraft.client.CameraType;
import net.minecraft.client.Minecraft;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.network.protocol.game.ServerboundAcceptTeleportationPacket;
import net.minecraft.network.protocol.game.ServerboundPlayerActionPacket;
import net.minecraft.network.protocol.game.ServerboundSetCarriedItemPacket;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;

final class TeleportFixture extends Fixture {
    // The inventory fixture supplies bread. Test isolation supplies stone.
    private static final int INITIAL_BREAD_COUNT = 17;
    private static final int INITIAL_STONE_COUNT = 8;
    private static final int BREAD_SLOT = 0;
    private static final int STONE_SLOT = 1;
    private static final int PEER_COUNT = 2;
    private static final int TIMEOUT_TICKS = 900;
    private static final int PROGRESS_INTERVAL_TICKS = 100;
    private static final double POSITION_TOLERANCE = 0.01;

    private static final Vec3 TELEPORT_TARGET = new Vec3(10.5, 65, 10.5);
    private static final Vec3 ISOLATION_START = new Vec3(8.5, 65, 10.5);
    private static final BlockPos SUPPORT_BLOCK = BlockPos.containing(TELEPORT_TARGET).below();
    private static final BlockPos PLACED_BLOCK = SUPPORT_BLOCK.above();
    private static final BlockPos MINING_BLOCK = SUPPORT_BLOCK.south();
    private static final String ISOLATION_SETUP = "world-isolation-setup";
    private static final String ISOLATION_SEPARATED = "world-isolation-separated";
    private static final String ISOLATION_DONE = "world-isolation-done";
    private static final String ISOLATION_OBSERVED = "world-isolation-observed";
    private static final String BOB_NOT_OPERATOR = "bob-not-op";
    private static final String TELEPORT_REPLY = "Teleported alice to bob";

    private record WorldHop(String commandWorld, String dimension, Block previousBlock,
                            Block destinationBlock, String teleportCommand) {}

    private static final List<WorldHop> WORLD_ROUTE = List.of(
        new WorldHop("nether", "the_nether", Blocks.GRASS_BLOCK, Blocks.NETHERRACK, "teleport bob"),
        new WorldHop("end", "the_end", Blocks.NETHERRACK, Blocks.END_STONE, "teleport alice bob"),
        new WorldHop("overworld_two", "overworld_two", Blocks.END_STONE, Blocks.STONE, "teleport bob"),
        new WorldHop("overworld", "overworld", Blocks.STONE, Blocks.GRASS_BLOCK, "teleport bob")
    );

    private enum AlicePhase {
        WAIT_FOR_PEERS, WAIT_FOR_MINING, WAIT_FOR_SEPARATION, WAIT_FOR_PLACEMENT, WAIT_FOR_REUNION,
        WAIT_FOR_ISOLATION_ACK,
        WAIT_FOR_PERMISSION_DENIAL, WAIT_FOR_COMPLETION, WAIT_FOR_FIRST_CONFIRMATION,
        WAIT_FOR_REPEATED_CONFIRMATION, WAIT_FOR_SAME_WORLD_POSITION,
        MOVE_BOB, WAIT_FOR_BOB_SEPARATION, WAIT_FOR_ARRIVAL, WAIT_FOR_BOB_ACK, DONE
    }

    private enum BobPhase {
        WAIT_FOR_SETUP, WAIT_BEFORE_MINING, WAIT_FOR_ISOLATION_DONE, WAIT_FOR_ISOLATION_CAPTURE,
        WAIT_FOR_PERMISSION_DENIAL, OBSERVE_WORLD_TRANSFERS, DONE
    }

    private AlicePhase alicePhase = AlicePhase.WAIT_FOR_PEERS;
    private BobPhase bobPhase = BobPhase.WAIT_FOR_SETUP;
    private int worldIndex;
    private final boolean isolation;
    private boolean breakingObserved;
    private boolean breakingCleared;
    private CompletableFuture<Suggestions> commandSuggestions;
    private volatile boolean holdTeleport;
    private volatile ServerboundAcceptTeleportationPacket heldTeleport;
    private LocalPlayer inventorySyncedPlayer;

    TeleportFixture(Recorder r) {
        super(r);
        isolation = r.scenario.equals("teleport-world-isolation");
    }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || game.player == null || game.level == null) return;
        boolean alice = r.peer.equals("alice");
        String phase = (alice ? alicePhase.name() : bobPhase.name());
        if (r.tick - r.terrainTick > TIMEOUT_TICKS) {
            client.fail("teleport_timeout_" + phase + "_world_" + worldIndex);
            return;
        }
        var root = game.getConnection().getCommands().getRoot();
        if (root.getChild("help") == null) return;
        if ((root.getChild("tp") != null) != alice || (root.getChild("teleport") != null) != alice) {
            client.fail("teleport_operator_permission");
            return;
        }
        if (r.tick % PROGRESS_INTERVAL_TICKS == 0)
            client.event("teleport_progress", "dimension", dimension(game), "players", game.level.players().size(), "phase", phase, "world_index", worldIndex);
        if (alice) tickAlice(game);
        else tickBob(game);
    }

    private void tickAlice(Minecraft game) {
        var handler = game.getConnection();
        switch (alicePhase) {
            case WAIT_FOR_PEERS -> {
                if (game.level.players().size() != PEER_COUNT || !breadIntact(game)) return;
                client.send("testisolation setup");
                alicePhase = AlicePhase.WAIT_FOR_MINING;
            }
            case WAIT_FOR_MINING -> {
                if (!close(game.player.getX(), ISOLATION_START.x, POSITION_TOLERANCE)
                    || !game.player.getInventory().getItem(STONE_SLOT).is(Items.STONE)) return;
                client.mark(ISOLATION_SETUP);
                if (!isolation) {
                    alicePhase = AlicePhase.WAIT_FOR_PERMISSION_DENIAL;
                    return;
                }
                if (!breakingObserved) return;
                breakingCleared = false;
                client.send("testisolation move");
                alicePhase = AlicePhase.WAIT_FOR_SEPARATION;
            }
            case WAIT_FOR_SEPARATION -> {
                if (!markerExists(ISOLATION_SEPARATED) || game.level.players().size() != 1 || !breakingCleared) return;
                selectSlot(game, STONE_SLOT);
                game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND,
                    new BlockHitResult(TELEPORT_TARGET, Direction.UP, SUPPORT_BLOCK, false));
                client.fence("isolation-placement");
                alicePhase = AlicePhase.WAIT_FOR_PLACEMENT;
            }
            case WAIT_FOR_PLACEMENT -> {
                if (!client.fenced("isolation-placement") || !assertWorldIsolation(game)) return;
                if (!client.screenshot("world_interactions_isolated").done()) return;
                client.send("testisolation verify");
                alicePhase = AlicePhase.WAIT_FOR_REUNION;
            }
            case WAIT_FOR_REUNION -> {
                if (!client.received("verify") || game.level.players().size() != PEER_COUNT) return;
                for (var player : game.level.players())
                    if (player != game.player && !isOriginalBread(player.getMainHandItem())) return;
                selectSlot(game, BREAD_SLOT);
                client.mark(ISOLATION_DONE);
                if (isolation) {
                    alicePhase = AlicePhase.WAIT_FOR_ISOLATION_ACK;
                    return;
                }
                alicePhase = AlicePhase.WAIT_FOR_PERMISSION_DENIAL;
            }
            case WAIT_FOR_ISOLATION_ACK -> {
                if (!markerExists(ISOLATION_OBSERVED)) return;
                alicePhase = AlicePhase.DONE;
                client.pass("world_interactions_isolated");
            }
            case WAIT_FOR_PERMISSION_DENIAL -> {
                if (!markerExists(BOB_NOT_OPERATOR)) return;
                var dispatcher = handler.getCommands();
                commandSuggestions = dispatcher.getCompletionSuggestions(dispatcher.parse("tp b", handler.getSuggestionsProvider()));
                alicePhase = AlicePhase.WAIT_FOR_COMPLETION;
            }
            case WAIT_FOR_COMPLETION -> {
                if (!commandSuggestions.isDone()) return;
                if (!commandSuggestions.join().getList().stream().map(value -> value.getText()).toList().equals(List.of("bob"))) {
                    client.fail("teleport_completion_missing");
                    return;
                }
                holdTeleportConfirmations(game);
                handler.sendCommand("tp bob");
                alicePhase = AlicePhase.WAIT_FOR_FIRST_CONFIRMATION;
            }
            case WAIT_FOR_FIRST_CONFIRMATION -> {
                if (heldTeleport == null || teleportReplyCount() < 1) return;
                // A second command must work while the first teleport is unconfirmed.
                heldTeleport = null;
                handler.sendCommand("tp bob");
                alicePhase = AlicePhase.WAIT_FOR_REPEATED_CONFIRMATION;
            }
            case WAIT_FOR_REPEATED_CONFIRMATION -> {
                if (heldTeleport == null || teleportReplyCount() < 2) return;
                holdTeleport = false;
                handler.send(heldTeleport);
                client.event("command_during_pending_teleport_verified");
                alicePhase = AlicePhase.WAIT_FOR_SAME_WORLD_POSITION;
            }
            case WAIT_FOR_SAME_WORLD_POSITION -> {
                if (!atTeleportTarget(game) || !game.player.onGround()) return;
                if (!markerExists("alice-same-world-ready")) client.mark("alice-same-world-ready");
                if (!markerExists("bob-same-world-equipment")) return;
                alicePhase = AlicePhase.MOVE_BOB;
            }
            case MOVE_BOB -> {
                client.send("testworld " + currentHop().commandWorld());
                alicePhase = AlicePhase.WAIT_FOR_BOB_SEPARATION;
            }
            case WAIT_FOR_BOB_SEPARATION -> {
                var hop = currentHop();
                if (!markerExists("bob-alone-" + hop.dimension())) return;
                if (!game.level.getBlockState(SUPPORT_BLOCK).is(hop.previousBlock())) {
                    client.fail("block_change_crossed_worlds");
                    return;
                }
                handler.sendCommand(hop.teleportCommand());
                alicePhase = AlicePhase.WAIT_FOR_ARRIVAL;
            }
            case WAIT_FOR_ARRIVAL -> {
                var hop = currentHop();
                if (!dimension(game).equals(hop.dimension()) || game.level.players().size() != PEER_COUNT
                    || !game.player.onGround() || inventorySyncedPlayer != game.player) return;
                if (!assertTeleportState(game)) return;
                if (!game.level.getBlockState(SUPPORT_BLOCK).is(hop.destinationBlock())) return;
                game.options.setCameraType(CameraType.THIRD_PERSON_BACK);
                client.mark("alice-joined-" + hop.dimension());
                alicePhase = AlicePhase.WAIT_FOR_BOB_ACK;
            }
            case WAIT_FOR_BOB_ACK -> {
                var hop = currentHop();
                if (!markerExists("bob-joined-" + hop.dimension())) return;
                if (!client.screenshot("teleport_" + hop.dimension()).done()) return;
                worldIndex++;
                if (worldIndex == WORLD_ROUTE.size()) {
                    alicePhase = AlicePhase.DONE;
                    client.pass("teleport_commands_and_world_transfers");
                } else alicePhase = AlicePhase.MOVE_BOB;
            }
            case DONE -> {}
        }
    }

    private void tickBob(Minecraft game) {
        switch (bobPhase) {
            case WAIT_FOR_SETUP -> {
                if (!markerExists(ISOLATION_SETUP) || !game.level.getBlockState(MINING_BLOCK).is(Blocks.STONE)) return;
                if (!isolation) {
                    game.getConnection().sendCommand("tp alice");
                    bobPhase = BobPhase.WAIT_FOR_PERMISSION_DENIAL;
                    return;
                }
                client.fence("isolation-mining");
                bobPhase = BobPhase.WAIT_BEFORE_MINING;
            }
            case WAIT_BEFORE_MINING -> {
                if (!client.fenced("isolation-mining")) return;
                game.getConnection().send(new ServerboundPlayerActionPacket(
                    ServerboundPlayerActionPacket.Action.START_DESTROY_BLOCK, MINING_BLOCK, Direction.UP, 0));
                bobPhase = BobPhase.WAIT_FOR_ISOLATION_DONE;
            }
            case WAIT_FOR_ISOLATION_DONE -> {
                if (dimension(game).equals(WORLD_ROUTE.getFirst().dimension()) && game.level.players().size() == 1)
                    client.mark(ISOLATION_SEPARATED);
                if (!markerExists(ISOLATION_DONE)) return;
                if (isolation) {
                    if (!dimension(game).equals("overworld") || game.level.players().size() != PEER_COUNT
                        || inventorySyncedPlayer != game.player || GuiApi.screen(game) != null) return;
                    bobPhase = BobPhase.WAIT_FOR_ISOLATION_CAPTURE;
                    return;
                }
                game.getConnection().sendCommand("tp alice");
                bobPhase = BobPhase.WAIT_FOR_PERMISSION_DENIAL;
            }
            case WAIT_FOR_ISOLATION_CAPTURE -> {
                if (!client.screenshot("world_interactions_isolated").done()) return;
                client.mark(ISOLATION_OBSERVED);
                bobPhase = BobPhase.DONE;
                client.pass("world_interactions_isolated");
            }
            case WAIT_FOR_PERMISSION_DENIAL -> {
                if (r.receivedChat.stream().noneMatch(text -> text.startsWith("Unknown command or insufficient permission"))) return;
                client.mark(BOB_NOT_OPERATOR);
                bobPhase = BobPhase.OBSERVE_WORLD_TRANSFERS;
            }
            case OBSERVE_WORLD_TRANSFERS -> {
                if (markerExists("alice-same-world-ready") && !markerExists("bob-same-world-equipment")) {
                    var alice = game.level.players().stream()
                        .filter(player -> ClientApi.profileName(player.getGameProfile()).equals("alice"))
                        .findFirst().orElse(null);
                    if (alice == null || !isOriginalBread(alice.getMainHandItem())) return;
                    if (!client.screenshot("same_world_teleport_equipment").done()) return;
                    client.mark("bob-same-world-equipment");
                }
                String destination = currentHop().dimension();
                if (!dimension(game).equals(destination)) return;
                if (game.level.players().size() == 1) client.mark("bob-alone-" + destination);
                if (!markerExists("alice-joined-" + destination) || game.level.players().size() != PEER_COUNT
                    || inventorySyncedPlayer != game.player) return;
                if (!breadIntact(game)) {
                    client.fail("teleport_inventory_lost");
                    return;
                }
                client.mark("bob-joined-" + destination);
                worldIndex++;
                if (worldIndex == WORLD_ROUTE.size()) {
                    bobPhase = BobPhase.DONE;
                    client.pass("teleport_non_op_and_world_isolation");
                }
            }
            case DONE -> {}
        }
    }

    private boolean assertWorldIsolation(Minecraft game) {
        if (!game.level.getBlockState(PLACED_BLOCK).is(Blocks.STONE)
            || game.player.getInventory().getItem(STONE_SLOT).getCount() != INITIAL_STONE_COUNT - 1) {
            client.fail("other_world_player_blocked_placement");
            return false;
        }
        if (!breadIntact(game)) {
            client.fail("cross_world_item_pickup");
            return false;
        }
        for (var entity : game.level.entitiesForRendering()) {
            if (entity instanceof net.minecraft.world.entity.item.ItemEntity) {
                client.fail("cross_world_item_visibility");
                return false;
            }
        }
        return true;
    }

    private boolean assertTeleportState(Minecraft game) {
        if (breadIntact(game) && atTeleportTarget(game)) return true;
        client.event("teleport_state_incorrect", "dimension", dimension(game),
            "bread_count", game.player.getInventory().getItem(BREAD_SLOT).getCount(),
            "x", game.player.getX(), "y", game.player.getY(), "z", game.player.getZ());
        client.fail("teleport_state_incorrect");
        return false;
    }

    private void holdTeleportConfirmations(Minecraft game) {
        holdTeleport = true;
        var channel = ((ClientConnectionAccessor) game.getConnection().getConnection()).lightningRod$channel();
        channel.pipeline().addLast("hold-teleport-confirmation", new ChannelOutboundHandlerAdapter() {
            @Override public void write(ChannelHandlerContext context, Object message, ChannelPromise promise) throws Exception {
                if (holdTeleport && message instanceof ServerboundAcceptTeleportationPacket confirmation) {
                    heldTeleport = confirmation;
                    promise.setSuccess();
                } else context.write(message, promise);
            }
        });
    }

    private long teleportReplyCount() {
        return r.receivedChat.stream().filter(TELEPORT_REPLY::equals).count();
    }

    private void selectSlot(Minecraft game, int slot) {
        game.player.getInventory().setSelectedSlot(slot);
        game.getConnection().send(new ServerboundSetCarriedItemPacket(slot));
    }

    private boolean breadIntact(Minecraft game) {
        return isOriginalBread(game.player.getInventory().getItem(BREAD_SLOT));
    }

    private boolean isOriginalBread(ItemStack stack) {
        return stack.is(Items.BREAD) && stack.getCount() == INITIAL_BREAD_COUNT;
    }

    private boolean atTeleportTarget(Minecraft game) {
        return close(game.player.getX(), TELEPORT_TARGET.x, POSITION_TOLERANCE)
            && close(game.player.getZ(), TELEPORT_TARGET.z, POSITION_TOLERANCE);
    }

    private boolean markerExists(String name) {
        return client.marked(name);
    }

    private String dimension(Minecraft game) {
        return GameApi.dimension(game).split(":", 2)[1];
    }

    private WorldHop currentHop() { return WORLD_ROUTE.get(worldIndex); }

    @Override void inventorySynced(Minecraft game) {
        // Each world change creates a new LocalPlayer. Wait for its inventory snapshot.
        inventorySyncedPlayer = game.player;
    }

    @Override public void blockBreaking(BlockPos position, int stage) {
        if (!position.equals(MINING_BLOCK)) return;
        if (stage >= 0 && stage < 10) breakingObserved = true;
        else breakingCleared = true;
        client.event("block_breaking", "stage", stage);
    }
}
