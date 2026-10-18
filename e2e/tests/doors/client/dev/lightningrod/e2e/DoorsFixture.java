package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.network.protocol.game.ServerboundMovePlayerPacket;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.DoorBlock;
import net.minecraft.world.level.block.state.properties.DoorHingeSide;
import net.minecraft.world.level.block.state.properties.DoubleBlockHalf;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;

final class DoorsFixture extends Fixture {
    private static final BlockPos[] DOORS = {
        new BlockPos(0, 65, 0), new BlockPos(4, 65, 0),
        new BlockPos(8, 65, 0), new BlockPos(12, 65, 0),
        new BlockPos(20, 79, 0)
    };
    private int door;
    private enum Phase {
        POSITION, READY, WAIT_READY, PLACED,
        WAIT_PLACED, OPEN, WAIT_OPEN, CLOSED,
        WAIT_CLOSED, SAVED, BLOCKED_POSITION, BLOCKED_PLACEMENT,
        RELOAD_READY, RELOADED, BREAK_POSITION, BREAK_READY,
        BROKEN, WAIT_BROKEN, DONE
    }
    private Phase phase = Phase.POSITION;
    private int broken;
    private boolean inventoryReady;
    private boolean reloadStatusRequested;
    private boolean repositioned;

    DoorsFixture(Recorder r) { super(r); }

    @Override void inventorySynced(Minecraft game) { inventoryReady = true; }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || GuiApi.screen(game) != null) return;
        if (r.tick - r.terrainTick > 1400) { client.fail("door_timeout_" + door + "_" + phase); return; }
        if (!inventoryReady) return;
        boolean alice = r.peer.equals("alice");
        try {
            if (door < DOORS.length) {
                var pos = DOORS[door];
                var facing = Direction.fromYRot((door % 4) * 90);
                var hinge = door % 2 == 0 ? DoorHingeSide.LEFT : DoorHingeSide.RIGHT;
                String prefix = "door-" + door + "-";
                if (phase == Phase.POSITION) {
                    double x = pos.getX() + 0.5 - facing.getStepX() * 2.5;
                    double z = pos.getZ() + 0.5 - facing.getStepZ() * 2.5;
                    if (!alice) { x += facing.getStepZ() * 1.5; z -= facing.getStepX() * 1.5; }
                    game.player.setPos(x, pos.getY(), z);
                    game.player.setYRot(alice ? door % 4 * 90 : (float)Math.toDegrees(Math.atan2(x - pos.getX() - 0.5, pos.getZ() + 0.5 - z)));
                    game.player.setXRot(20);
                    game.getConnection().send(new ServerboundMovePlayerPacket.PosRot(x, pos.getY(), z, game.player.getYRot(), 20, true, false));
                    if (alice) {
                        var stack = new ItemStack(Items.OAK_DOOR, 16);
                        game.player.getInventory().setSelectedSlot(0);
                        game.player.getInventory().setItem(0, stack);
                        game.gameMode.handleCreativeModeItemAdd(stack, 36);
                    }
                    client.fence(prefix + "position");
                    phase = Phase.READY;
                }
                if (missingChunks(game, 1) != 0 || !client.fenced(prefix + "position")) return;
                if (phase == Phase.READY) {
                    var subject = game.level.players().stream().filter(p -> p.getName().getString().equals("alice")).findFirst().orElse(null);
                    if (subject == null || !subject.getMainHandItem().is(Items.OAK_DOOR)) return;
                    client.mark(r.peer + "." + prefix + "ready");
                    phase = Phase.WAIT_READY;
                }
                if (phase == Phase.WAIT_READY || phase == Phase.WAIT_PLACED || phase == Phase.WAIT_OPEN || phase == Phase.WAIT_CLOSED) {
                    String barrier = switch (phase) { case WAIT_READY -> "ready"; case WAIT_PLACED -> "placed"; case WAIT_OPEN -> "open"; default -> "closed"; };
                    for (String peer : r.expectedPeers) if (!client.marked(peer + "." + prefix + barrier)) return;
                    if (alice) {
                        if (phase == Phase.WAIT_READY) {
                            double x = 0.5, z = 0.5;
                            if (hinge == DoorHingeSide.RIGHT) {
                                if (facing.getStepX() != 0) z += facing.getStepX() * 0.25;
                                else x -= facing.getStepZ() * 0.25;
                            }
                            var result = game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND,
                                new BlockHitResult(new Vec3(pos.getX() + x, pos.getY(), pos.getZ() + z), Direction.UP, pos.below(), false));
                            client.event("door_place", "door", door, "result", result.toString(), "yaw", game.player.getYRot());
                        } else if (phase != Phase.WAIT_CLOSED || door % 2 != 0) {
                            var target = phase == Phase.WAIT_OPEN ? pos : pos.above();
                            game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND,
                                new BlockHitResult(Vec3.atCenterOf(target), facing.getOpposite(), target, false));
                        }
                    }
                    phase = switch (phase) {
                        case WAIT_READY -> Phase.PLACED;
                        case WAIT_PLACED -> Phase.OPEN;
                        case WAIT_OPEN -> Phase.CLOSED;
                        case WAIT_CLOSED -> Phase.SAVED;
                        default -> throw new AssertionError(phase);
                    };
                }
                if (phase == Phase.PLACED || phase == Phase.OPEN || phase == Phase.CLOSED || phase == Phase.SAVED) {
                    boolean open = phase == Phase.OPEN || (phase == Phase.SAVED && door % 2 != 0);
                    for (int half = 0; half < 2; half++) {
                        var state = game.level.getBlockState(pos.above(half));
                        if (!state.is(Blocks.OAK_DOOR) || state.getValue(DoorBlock.FACING) != facing || state.getValue(DoorBlock.HINGE) != hinge
                            || state.getValue(DoorBlock.HALF) != (half == 0 ? DoubleBlockHalf.LOWER : DoubleBlockHalf.UPPER)
                            || state.getValue(DoorBlock.OPEN) != open || state.getValue(DoorBlock.POWERED)) {
                            if (r.tick % 100 == 0) client.event("door_wait", "door", door, "stage", phase, "half", half, "state", state.toString());
                            return;
                        }
                    }
                    if (!game.levelRenderer.hasRenderedAllSections()) {
                        if (r.tick % 100 == 0) client.event("door_render_wait", "door", door, "stage", phase,
                            "terrain_complete", game.levelRenderer.hasRenderedAllSections());
                        return;
                    }
                    String label = switch (phase) { case PLACED -> "placed"; case OPEN -> "open"; case CLOSED -> "closed"; default -> "saved"; };
                    if (!client.screenshot(prefix + label).done()) return;
                    client.event("door_verified", "door", door, "facing", facing.getSerializedName(), "hinge", hinge.getSerializedName(), "open", open, "stage", label);
                    client.mark(r.peer + "." + prefix + label);
                    if (phase == Phase.SAVED) { door++; phase = Phase.POSITION; } else phase = switch (phase) {
                        case PLACED -> Phase.WAIT_PLACED;
                        case OPEN -> Phase.WAIT_OPEN;
                        case CLOSED -> Phase.WAIT_CLOSED;
                        default -> throw new AssertionError(phase);
                    };
                }
                return;
            }
            if (phase == Phase.POSITION) {
                for (String peer : r.expectedPeers) if (!client.marked(peer + ".door-4-saved")) return;
                game.player.setPos(alice ? 24.5 : 26.5, 65, -2.5);
                game.player.setYRot(0);
                game.player.setXRot(20);
                game.getConnection().send(new ServerboundMovePlayerPacket.PosRot(game.player.getX(), 65, -2.5, 0, 20, true, false));
                client.fence("blocked-door-position");
                phase = Phase.BLOCKED_POSITION;
            }
            if (phase == Phase.BLOCKED_POSITION && client.fenced("blocked-door-position")) {
                client.mark(r.peer + ".blocked-door-ready");
                for (String peer : r.expectedPeers) if (!client.marked(peer + ".blocked-door-ready")) return;
                if (alice && !client.marked("blocked-door-attempted")) {
                    game.gameMode.useItemOn(game.player, InteractionHand.MAIN_HAND,
                        new BlockHitResult(new Vec3(24.5, 65, 0.5), Direction.UP, new BlockPos(24, 64, 0), false));
                    client.mark("blocked-door-attempted");
                }
                if (!client.marked("blocked-door-attempted")) return;
                client.fence("blocked-door-placement");
                phase = Phase.BLOCKED_PLACEMENT;
            }
            if (phase == Phase.BLOCKED_PLACEMENT && client.fenced("blocked-door-placement")) {
                if (!game.level.getBlockState(new BlockPos(24, 65, 0)).isAir() || !game.level.getBlockState(new BlockPos(24, 66, 0)).is(Blocks.STONE)) {
                    client.fail("blocked_door_placement_changed_world"); return;
                }
                if (!client.screenshot("blocked_placement").done()) return;
                client.mark(r.peer + ".doors-reload-ready");
                phase = Phase.RELOAD_READY;
            }
            if (phase == Phase.RELOAD_READY) {
                for (String peer : r.expectedPeers) if (!client.marked(peer + ".doors-reload-ready")) return;
                if (alice) client.reload();
                phase = Phase.RELOADED;
            }
            if (phase == Phase.RELOADED && r.joins == 2) {
                if (game.level.players().size() != 2) return;
                for (int i = 0; i < DOORS.length; i++) {
                    for (int half = 0; half < 2; half++) {
                        var state = game.level.getBlockState(DOORS[i].above(half));
                        if (!state.is(Blocks.OAK_DOOR)) return;
                        if (state.getValue(DoorBlock.FACING) != Direction.fromYRot(i % 4 * 90)
                            || state.getValue(DoorBlock.HINGE) != (i % 2 == 0 ? DoorHingeSide.LEFT : DoorHingeSide.RIGHT)
                            || state.getValue(DoorBlock.HALF) != (half == 0 ? DoubleBlockHalf.LOWER : DoubleBlockHalf.UPPER)
                            || state.getValue(DoorBlock.OPEN) != (i % 2 != 0) || state.getValue(DoorBlock.POWERED)) {
                            client.fail("door_state_changed_after_reload_" + i); return;
                        }
                    }
                }
                if (!reloadStatusRequested) { client.send("reload_status"); reloadStatusRequested = true; }
                if (client.received("reload rolled_back")) { client.fail("door_reload_rolled_back"); return; }
                if (!client.received("reload succeeded")) return;
                if (!repositioned) {
                    game.player.setPos(alice ? 0.5 : 2.0, 65, -3.5);
                    game.player.setYRot(alice ? 0 : 20.56f);
                    game.player.setXRot(10);
                    repositioned = true;
                    client.fence("doors-repositioned");
                    return;
                }
                if (missingChunks(game, 1) != 0 || !client.fenced("doors-repositioned") || !game.levelRenderer.hasRenderedAllSections()) return;
                if (!client.screenshot("doors_after_reload").done()) return;
                client.mark(r.peer + ".doors-restored");
                phase = Phase.BREAK_POSITION;
            }
            if (phase == Phase.BREAK_POSITION) {
                for (String peer : r.expectedPeers) if (!client.marked(peer + ".doors-restored")) return;
                var pos = DOORS[broken];
                game.player.setPos(pos.getX() + (alice ? 0.5 : 2.0), 65, -2.5);
                game.player.setYRot(0);
                game.player.setXRot(10);
                game.getConnection().send(new ServerboundMovePlayerPacket.PosRot(game.player.getX(), 65, -2.5, 0, 10, true, false));
                client.fence("door-break-position-" + broken);
                phase = Phase.BREAK_READY;
            }
            if (phase == Phase.BREAK_READY && client.fenced("door-break-position-" + broken)) {
                client.mark(r.peer + ".door-break-ready-" + broken);
                for (String peer : r.expectedPeers) if (!client.marked(peer + ".door-break-ready-" + broken)) return;
                if (alice) game.gameMode.startDestroyBlock(DOORS[broken].above(broken), Direction.NORTH);
                phase = Phase.BROKEN;
            }
            if (phase == Phase.BROKEN) {
                var lower = game.level.getBlockState(DOORS[broken]);
                var upper = game.level.getBlockState(DOORS[broken].above());
                if (!lower.isAir() || !upper.isAir()) {
                    if (r.tick % 100 == 0) client.event("door_break_wait", "door", broken, "lower", lower.toString(), "upper", upper.toString());
                    return;
                }
                if (!game.levelRenderer.hasRenderedAllSections()) return;
                if (!client.screenshot("door_broken_" + (broken == 0 ? "lower" : "upper")).done()) return;
                client.mark(r.peer + ".door-broken-" + broken);
                phase = Phase.WAIT_BROKEN;
            }
            if (phase == Phase.WAIT_BROKEN) {
                for (String peer : r.expectedPeers) if (!client.marked(peer + ".door-broken-" + broken)) return;
                if (++broken < 2) phase = Phase.BREAK_POSITION;
                else { phase = Phase.DONE; client.pass("door_halves_facing_hinges_interaction_reload_and_breaking"); }
            }
        } catch (Exception error) {
            client.fail("door_test_error_" + error);
        }
    }
}
