package dev.lightningrod.e2e;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import net.minecraft.client.Minecraft;
import net.minecraft.util.Mth;

final class PlayerSyncFixture extends Fixture {
    private boolean syncStarted;
    private boolean syncPublished;
    private long syncObservedTick = -1;
    private long syncStartTick = -1;

    PlayerSyncFixture(Recorder r) { super(r); }

    public void tick(Minecraft client, int loaded, int missing) {
        if (loaded < 9 || r.terrainTick < 0) return;
        if (r.peer.equals("alice")) {
            if (!syncStarted) {
                if (missing != 0) return;
                syncStarted = true;
                syncStartTick = r.tick;
                client.player.setYRot(90.0f);
                client.player.setYHeadRot(90.0f);
                client.player.setYBodyRot(90.0f);
                client.options.keyShift.setDown(true);
                client.options.keyUp.setDown(true);
                r.screenshot(client, "player_sync_alice_input");
                r.event("player_sync_input", "yaw", 90.0f, "sneaking", true);
            }
            if (r.tick - syncStartTick >= 30) client.options.keyUp.setDown(false);
            if (!syncPublished && r.tick - syncStartTick >= 40) {
                syncPublished = true;
                writeSync("alice.sync", client.player.getX(), client.player.getY(), client.player.getZ(),
                    client.player.getYRot(), client.player.getYHeadRot(), client.player.getVisualRotationYInDegrees(), client.player.isShiftKeyDown());
                r.event("player_sync_published", "x", client.player.getX(), "y", client.player.getY(), "z", client.player.getZ(),
                    "yaw", client.player.getYRot(), "head_yaw", client.player.getYHeadRot(), "body_yaw", client.player.getVisualRotationYInDegrees(), "sneaking", client.player.isShiftKeyDown());
            }
            if (syncPublished && r.expectedPeers.stream().allMatch(peer -> Files.exists(r.artifacts.resolve(peer + ".sync")))) {
                r.pass(client, "player_state_observed_by_peers");
            }
            return;
        }
        if (!syncStarted) {
            syncStarted = true;
            client.player.setPos(0.5, 65, 3.5 + 2 * r.expectedPeers.indexOf(r.peer));
            return;
        }
        if (missing != 0) return;
        if (!Files.exists(r.artifacts.resolve("alice.sync"))) return;
        var alice = client.level.players().stream()
            .filter(player -> ClientApi.profileName(player.getGameProfile()).equals("alice"))
            .findFirst().orElse(null);
        if (alice == null) return;
        try {
            String[] expected = Files.readString(r.artifacts.resolve("alice.sync"), StandardCharsets.UTF_8).trim().split(" ");
            if (expected.length != 7) { r.fail(client, "player_sync_expectation_invalid"); return; }
            boolean matches = r.close(alice.getX(), Double.parseDouble(expected[0]), 0.05)
                && r.close(alice.getY(), Double.parseDouble(expected[1]), 0.05)
                && r.close(alice.getZ(), Double.parseDouble(expected[2]), 0.05)
                && r.angleClose(alice.getYRot(), Float.parseFloat(expected[3]))
                && r.angleClose(alice.getYHeadRot(), Float.parseFloat(expected[4]))
                // LivingEntity.turnHead derives body yaw locally and clamps it to 50 degrees from view yaw.
                && Math.abs(Mth.wrapDegrees(alice.getYRot() - alice.getVisualRotationYInDegrees())) <= 50.01f
                && alice.isShiftKeyDown() == Boolean.parseBoolean(expected[6])
                && alice.getPose() == net.minecraft.world.entity.Pose.CROUCHING
                && !alice.isOnFire() && !alice.isSprinting() && !alice.isSwimming()
                && !alice.isInvisible() && !alice.isCurrentlyGlowing() && !alice.isFallFlying();
            if (!matches) {
                if (r.tick % 100 == 0) r.event("player_sync_mismatch", "x", alice.getX(), "y", alice.getY(), "z", alice.getZ(),
                    "yaw", alice.getYRot(), "head_yaw", alice.getYHeadRot(), "body_yaw", alice.getVisualRotationYInDegrees(), "sneaking", alice.isShiftKeyDown());
                return;
            }
            if (syncObservedTick < 0) {
                syncObservedTick = r.tick;
                double dx = alice.getX() - client.player.getX();
                double dz = alice.getZ() - client.player.getZ();
                double dy = alice.getY() + 0.8 - client.player.getEyeY();
                client.player.setYRot((float) Math.toDegrees(Math.atan2(-dx, dz)));
                client.player.setXRot((float) -Math.toDegrees(Math.atan2(dy, Math.hypot(dx, dz))));
                return;
            }
            if (r.tick - syncObservedTick < 5) return;
            writeSync(r.peer + ".sync", alice.getX(), alice.getY(), alice.getZ(), alice.getYRot(), alice.getYHeadRot(), alice.getVisualRotationYInDegrees(), alice.isShiftKeyDown());
            r.event("player_sync_observed", "x", alice.getX(), "y", alice.getY(), "z", alice.getZ(), "yaw", alice.getYRot(),
                "head_yaw", alice.getYHeadRot(), "body_yaw", alice.getVisualRotationYInDegrees(), "sneaking", alice.isShiftKeyDown());
            r.screenshot(client, "player_sync_observed");
            r.pass(client, "replicated_position_rotation_and_sneak_state");
        } catch (IOException | NumberFormatException error) {
            r.fail(client, "player_sync_expectation_unreadable");
        }
    }

    private void writeSync(String name, double x, double y, double z, float yaw, float headYaw, float bodyYaw, boolean sneaking) {
        try {
            Files.writeString(r.artifacts.resolve(name), String.format(java.util.Locale.ROOT, "%f %f %f %f %f %f %s\n", x, y, z, yaw, headYaw, bodyYaw, sneaking), StandardCharsets.UTF_8);
        } catch (IOException error) {
            throw new IllegalStateException("cannot write player-sync expectation", error);
        }
    }

}
