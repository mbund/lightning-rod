package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.network.protocol.game.ClientboundAddEntityPacket;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Blocks;

final class PlayerOcclusionFixture extends Fixture {
    private static final BlockPos SURFACE = new BlockPos(20, 64, 20);
    private static final BlockPos UPPER_AIR = new BlockPos(20, 303, 20);
    private static final BlockPos HIDDEN_SHAFT = new BlockPos(21, 48, 20);
    private static final BlockPos CEILING = new BlockPos(21, 32, 20);
    private static final BlockPos EDIT = new BlockPos(22, 17, 20);
    private enum Phase { HIDDEN, VISIBLE, EDITING, HIDDEN_AGAIN, VISIBLE_AGAIN, VERIFIED }
    private Phase phase = Phase.HIDDEN;
    private boolean checked;
    private int spawns;
    private long started;
    private boolean placed;

    PlayerOcclusionFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }
    @Override int renderDistance() { return 2; }
    @Override boolean prepare(Minecraft game) { return true; }

    @Override void entitySpawned(ClientboundAddEntityPacket packet) {
        if (!BuiltInRegistries.ENTITY_TYPE.getKey(packet.getType()).toString().equals("minecraft:player")) return;
        if (phase == Phase.HIDDEN) client.fail("concealed_player_spawn_packet_received");
        spawns++;
        if (phase == Phase.EDITING) client.fail("visible_edit_respawned_player");
        if (spawns > 2) client.fail("duplicate_player_spawn");
    }

    @Override void chunkData(Minecraft game, int x, int z) {
        if (phase == Phase.EDITING) client.fail("visible_edit_resent_chunk_" + x + "_" + z);
    }

    @Override void message(String text) {
        placed = text.equals("edit_placed");
        phase = switch (text) {
            case "opened" -> Phase.VISIBLE;
            case "edit_placed", "edit_broken" -> Phase.EDITING;
            case "closed" -> Phase.HIDDEN_AGAIN;
            case "reopened" -> Phase.VISIBLE_AGAIN;
            case "verified" -> Phase.VERIFIED;
            default -> throw new IllegalArgumentException(text);
        };
        checked = false;
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || r.terrainTick < 0) return;
        if (started == 0) started = System.nanoTime();
        boolean other = game.level.players().stream().anyMatch(player -> player.getId() != game.player.getId());
        if (System.nanoTime() - started > 30_000_000_000L) { client.fail("player_occlusion_timeout_phase_" + phase + "_spawns_" + spawns + "_entity_" + other + "_ceiling_" + game.level.getBlockState(CEILING)); return; }
        if (phase == Phase.HIDDEN && (other || spawns != 0)) { client.fail("concealed_player_disclosed"); return; }
        if (phase == Phase.EDITING && (!other || spawns != 1)) { client.fail("visible_edit_hid_player"); return; }
        if (phase == Phase.VERIFIED) { client.pass("players_hidden_revealed_hidden_and_revealed_again"); return; }
        if (loaded < 25 || missing != 0 || checked) return;
        game.player.setXRot(r.peer.equals("alice") ? 90 : -90);
        switch (phase) {
            case EDITING -> {
                if (!game.level.getBlockState(EDIT).is(placed ? Blocks.STONE : Blocks.AIR)) return;
                client.send("edit_checked");
            }
            case HIDDEN -> {
                if (r.peer.equals("bob") && (!game.level.getBlockState(SURFACE).is(Blocks.AIR)
                        || !game.level.getBlockState(UPPER_AIR).is(Blocks.AIR))) {
                    client.fail("surface_above_sealed_cave_disclosed");
                    return;
                }
                if (!client.screenshot("other_player_concealed").done()) return;
                client.send("hidden_checked");
            }
            case VISIBLE, VISIBLE_AGAIN -> {
                int expected = phase == Phase.VISIBLE ? 1 : 2;
                if (!other || spawns != expected) return;
                if (r.peer.equals("bob") && !game.level.getBlockState(SURFACE).is(Blocks.GRASS_BLOCK)) return;
                if (r.peer.equals("bob") && !game.level.getBlockState(UPPER_AIR).isAir()) return;
                if (r.peer.equals("bob") && !game.level.getBlockState(HIDDEN_SHAFT).isAir()) return;
                if (!client.screenshot(phase == Phase.VISIBLE ? "other_player_revealed" : "other_player_revealed_again").done()) return;
                client.send(phase == Phase.VISIBLE ? "visible_checked" : "visible_again_checked");
            }
            case HIDDEN_AGAIN -> {
                if (other || spawns != 1) return;
                if (r.peer.equals("bob") && !game.level.getBlockState(CEILING).is(Blocks.STONE)) return;
                if (!client.screenshot("other_player_hidden_again").done()) return;
                client.send("hidden_again_checked");
            }
            default -> throw new IllegalStateException(phase.toString());
        }
        checked = true;
    }
}
