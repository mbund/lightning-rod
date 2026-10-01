package dev.lightningrod.e2e;

import java.nio.file.Files;
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
    private int stage;
    private int broken;
    private long started;
    private long stable = -1;

    DoorsFixture(Recorder r) { super(r); }

    @Override void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0 || GuiApi.screen(client) != null) return;
        if (r.tick - r.terrainTick > 1400) { r.fail(client, "door_timeout_" + door + "_" + stage); return; }
        boolean alice = r.peer.equals("alice");
        try {
            if (door < DOORS.length) {
                var pos = DOORS[door];
                var facing = Direction.fromYRot((door % 4) * 90);
                var hinge = door % 2 == 0 ? DoorHingeSide.LEFT : DoorHingeSide.RIGHT;
                String prefix = "door-" + door + "-";
                if (stage == 0) {
                    double x = pos.getX() + 0.5 - facing.getStepX() * 2.5;
                    double z = pos.getZ() + 0.5 - facing.getStepZ() * 2.5;
                    if (!alice) { x += facing.getStepZ() * 1.5; z -= facing.getStepX() * 1.5; }
                    client.player.setPos(x, pos.getY(), z);
                    client.player.setYRot(alice ? door % 4 * 90 : (float)Math.toDegrees(Math.atan2(x - pos.getX() - 0.5, pos.getZ() + 0.5 - z)));
                    client.player.setXRot(20);
                    client.getConnection().send(new ServerboundMovePlayerPacket.PosRot(x, pos.getY(), z, client.player.getYRot(), 20, true, false));
                    if (alice) {
                        var stack = new ItemStack(Items.OAK_DOOR, 16);
                        client.player.getInventory().setSelectedSlot(0);
                        client.player.getInventory().setItem(0, stack);
                        client.gameMode.handleCreativeModeItemAdd(stack, 36);
                    }
                    started = r.tick;
                    stage = 1;
                }
                if (r.missingChunks(client, 1) != 0 || r.tick - started < 10) return;
                if (stage == 1) {
                    var subject = client.level.players().stream().filter(p -> p.getName().getString().equals("alice")).findFirst().orElse(null);
                    if (subject == null || !subject.getMainHandItem().is(Items.OAK_DOOR)) return;
                    r.marker(r.peer + "." + prefix + "ready");
                    stage = 2;
                }
                if (stage == 2 || stage == 4 || stage == 6 || stage == 8) {
                    String barrier = switch (stage) { case 2 -> "ready"; case 4 -> "placed"; case 6 -> "open"; default -> "closed"; };
                    for (String peer : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(peer + "." + prefix + barrier))) return;
                    if (alice) {
                        if (stage == 2) {
                            double x = 0.5, z = 0.5;
                            if (hinge == DoorHingeSide.RIGHT) {
                                if (facing.getStepX() != 0) z += facing.getStepX() * 0.25;
                                else x -= facing.getStepZ() * 0.25;
                            }
                            var result = client.gameMode.useItemOn(client.player, InteractionHand.MAIN_HAND,
                                new BlockHitResult(new Vec3(pos.getX() + x, pos.getY(), pos.getZ() + z), Direction.UP, pos.below(), false));
                            r.event("door_place", "door", door, "result", result.toString(), "yaw", client.player.getYRot());
                        } else if (stage != 8 || door % 2 != 0) {
                            var target = stage == 6 ? pos : pos.above();
                            client.gameMode.useItemOn(client.player, InteractionHand.MAIN_HAND,
                                new BlockHitResult(Vec3.atCenterOf(target), facing.getOpposite(), target, false));
                        }
                    }
                    stage++;
                    stable = -1;
                }
                if (stage == 3 || stage == 5 || stage == 7 || stage == 9) {
                    boolean open = stage == 5 || (stage == 9 && door % 2 != 0);
                    for (int half = 0; half < 2; half++) {
                        var state = client.level.getBlockState(pos.above(half));
                        if (!state.is(Blocks.OAK_DOOR) || state.getValue(DoorBlock.FACING) != facing || state.getValue(DoorBlock.HINGE) != hinge
                            || state.getValue(DoorBlock.HALF) != (half == 0 ? DoubleBlockHalf.LOWER : DoubleBlockHalf.UPPER)
                            || state.getValue(DoorBlock.OPEN) != open || state.getValue(DoorBlock.POWERED)) {
                            if (r.tick % 100 == 0) r.event("door_wait", "door", door, "stage", stage, "half", half, "state", state.toString());
                            stable = -1; return;
                        }
                    }
                    if (stable < 0) stable = r.tick;
                    if (r.tick - stable < 10 || !client.levelRenderer.hasRenderedAllSections()) {
                        if (r.tick % 100 == 0) r.event("door_render_wait", "door", door, "stage", stage, "stable", stable,
                            "terrain_complete", client.levelRenderer.hasRenderedAllSections());
                        return;
                    }
                    String label = switch (stage) { case 3 -> "placed"; case 5 -> "open"; case 7 -> "closed"; default -> "saved"; };
                    r.screenshot(client, prefix + label);
                    r.event("door_verified", "door", door, "facing", facing.getSerializedName(), "hinge", hinge.getSerializedName(), "open", open, "stage", label);
                    r.marker(r.peer + "." + prefix + label);
                    if (stage == 9) { door++; stage = 0; } else stage++;
                }
                return;
            }
            if (stage == 0) {
                for (String peer : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(peer + ".door-4-saved"))) return;
                client.player.setPos(alice ? 24.5 : 26.5, 65, -2.5);
                client.player.setYRot(0);
                client.player.setXRot(20);
                client.getConnection().send(new ServerboundMovePlayerPacket.PosRot(client.player.getX(), 65, -2.5, 0, 20, true, false));
                started = r.tick;
                stage = 20;
            }
            if (stage == 20 && r.tick - started >= 10) {
                if (alice) client.gameMode.useItemOn(client.player, InteractionHand.MAIN_HAND,
                    new BlockHitResult(new Vec3(24.5, 65, 0.5), Direction.UP, new BlockPos(24, 64, 0), false));
                stage = 21;
            }
            if (stage == 21 && r.tick - started >= 30) {
                if (!client.level.getBlockState(new BlockPos(24, 65, 0)).isAir() || !client.level.getBlockState(new BlockPos(24, 66, 0)).is(Blocks.STONE)) {
                    r.fail(client, "blocked_door_placement_changed_world"); return;
                }
                r.screenshot(client, "blocked_placement");
                r.marker(r.peer + ".doors-reload-ready");
                stage = 22;
            }
            if (stage == 22) {
                for (String peer : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(peer + ".doors-reload-ready"))) return;
                if (alice) client.getConnection().sendCommand("reload");
                stable = -1;
                stage = 23;
            }
            if (stage == 23 && r.joins == 2) {
                if (client.level.players().size() != 2) return;
                for (int i = 0; i < DOORS.length; i++) {
                    for (int half = 0; half < 2; half++) {
                        var state = client.level.getBlockState(DOORS[i].above(half));
                        if (!state.is(Blocks.OAK_DOOR)) return;
                        if (state.getValue(DoorBlock.FACING) != Direction.fromYRot(i % 4 * 90)
                            || state.getValue(DoorBlock.HINGE) != (i % 2 == 0 ? DoorHingeSide.LEFT : DoorHingeSide.RIGHT)
                            || state.getValue(DoorBlock.HALF) != (half == 0 ? DoubleBlockHalf.LOWER : DoubleBlockHalf.UPPER)
                            || state.getValue(DoorBlock.OPEN) != (i % 2 != 0) || state.getValue(DoorBlock.POWERED)) {
                            r.fail(client, "door_state_changed_after_reload_" + i); return;
                        }
                    }
                }
                String log = Files.readString(r.artifacts.resolve("server.log"));
                if (!log.contains("event=reload_resumed ") || log.contains("event=reload_fallback ")) {
                    r.fail(client, "door_test_did_not_exec_reload"); return;
                }
                if (stable < 0) {
                    client.player.setPos(alice ? 0.5 : 2.0, 65, -3.5);
                    client.player.setYRot(alice ? 0 : 20.56f);
                    client.player.setXRot(10);
                    stable = r.tick;
                    return;
                }
                if (r.missingChunks(client, 1) != 0 || r.tick - stable < 20 || !client.levelRenderer.hasRenderedAllSections()) return;
                r.screenshot(client, "doors_after_reload");
                r.marker(r.peer + ".doors-restored");
                started = r.tick;
                stage = 24;
            }
            if (stage == 24) {
                if (r.tick - started < 10) return;
                for (String peer : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(peer + ".doors-restored"))) return;
                var pos = DOORS[broken];
                client.player.setPos(pos.getX() + (alice ? 0.5 : 2.0), 65, -2.5);
                client.player.setYRot(0);
                client.player.setXRot(10);
                client.getConnection().send(new ServerboundMovePlayerPacket.PosRot(client.player.getX(), 65, -2.5, 0, 10, true, false));
                started = r.tick;
                stage = 25;
            }
            if (stage == 25 && r.tick - started >= 10) {
                r.marker(r.peer + ".door-break-ready-" + broken);
                for (String peer : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(peer + ".door-break-ready-" + broken))) return;
                if (alice) client.gameMode.startDestroyBlock(DOORS[broken].above(broken), Direction.NORTH);
                stable = -1;
                stage = 26;
            }
            if (stage == 26) {
                var lower = client.level.getBlockState(DOORS[broken]);
                var upper = client.level.getBlockState(DOORS[broken].above());
                if (!lower.isAir() || !upper.isAir()) {
                    if (r.tick % 100 == 0) r.event("door_break_wait", "door", broken, "lower", lower.toString(), "upper", upper.toString());
                    return;
                }
                if (stable < 0) stable = r.tick;
                if (r.tick - stable < 10 || !client.levelRenderer.hasRenderedAllSections()) return;
                r.screenshot(client, "door_broken_" + (broken == 0 ? "lower" : "upper"));
                r.marker(r.peer + ".door-broken-" + broken);
                stage = 27;
            }
            if (stage == 27) {
                for (String peer : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(peer + ".door-broken-" + broken))) return;
                if (++broken < 2) stage = 24;
                else { stage = 28; r.pass(client, "door_halves_facing_hinges_interaction_reload_and_breaking"); }
            }
        } catch (Exception error) {
            r.fail(client, "door_test_error_" + error);
        }
    }
}
