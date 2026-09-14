package dev.lightningrod.e2e;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import net.minecraft.client.MinecraftClient;
import net.minecraft.util.math.MathHelper;

final class PlayerSyncFixture extends Fixture {
    private boolean syncStarted;
    private boolean syncPublished;
    private long syncObservedTick = -1;
    private long syncStartTick = -1;

    PlayerSyncFixture(Recorder r) { super(r); }

    public void tick(MinecraftClient client, int loaded, int missing) {
        if (loaded < 9 || r.terrainTick < 0) return;
        if (r.peer.equals("alice")) {
            if (!syncStarted) {
                if (missing != 0) return;
                syncStarted = true;
                syncStartTick = r.tick;
                client.player.setYaw(90.0f);
                client.player.setHeadYaw(90.0f);
                client.player.setBodyYaw(90.0f);
                client.options.sneakKey.setPressed(true);
                client.options.forwardKey.setPressed(true);
                r.screenshot(client, "player_sync_alice_input");
                r.event("player_sync_input", "yaw", 90.0f, "sneaking", true);
            }
            if (r.tick - syncStartTick >= 30) client.options.forwardKey.setPressed(false);
            if (!syncPublished && r.tick - syncStartTick >= 40) {
                syncPublished = true;
                writeSync("alice.sync", client.player.getX(), client.player.getY(), client.player.getZ(),
                    client.player.getYaw(), client.player.getHeadYaw(), client.player.getBodyYaw(), client.player.isSneaking());
                r.event("player_sync_published", "x", client.player.getX(), "y", client.player.getY(), "z", client.player.getZ(),
                    "yaw", client.player.getYaw(), "head_yaw", client.player.getHeadYaw(), "body_yaw", client.player.getBodyYaw(), "sneaking", client.player.isSneaking());
            }
            if (syncPublished && Files.exists(r.artifacts.resolve("bob.sync")) && Files.exists(r.artifacts.resolve("carol.sync"))) {
                r.pass(client, "player_state_observed_by_peers");
            }
            return;
        }
        if (!syncStarted) {
            syncStarted = true;
            client.player.setPosition(0.5, 65, r.peer.equals("bob") ? 4.5 : -3.5);
            return;
        }
        if (missing != 0) return;
        if (!Files.exists(r.artifacts.resolve("alice.sync"))) return;
        var alice = client.world.getPlayers().stream()
            .filter(player -> player.getGameProfile().getName().equals("alice"))
            .findFirst().orElse(null);
        if (alice == null) return;
        try {
            String[] expected = Files.readString(r.artifacts.resolve("alice.sync"), StandardCharsets.UTF_8).trim().split(" ");
            if (expected.length != 7) { r.fail(client, "player_sync_expectation_invalid"); return; }
            boolean matches = r.close(alice.getX(), Double.parseDouble(expected[0]), 0.05)
                && r.close(alice.getY(), Double.parseDouble(expected[1]), 0.05)
                && r.close(alice.getZ(), Double.parseDouble(expected[2]), 0.05)
                && r.angleClose(alice.getYaw(), Float.parseFloat(expected[3]))
                && r.angleClose(alice.getHeadYaw(), Float.parseFloat(expected[4]))
                // LivingEntity.turnHead derives body yaw locally and clamps it to 50 degrees from view yaw.
                && Math.abs(MathHelper.wrapDegrees(alice.getYaw() - alice.getBodyYaw())) <= 50.01f
                && alice.isSneaking() == Boolean.parseBoolean(expected[6])
                && alice.getPose() == net.minecraft.entity.EntityPose.CROUCHING
                && !alice.isOnFire() && !alice.isSprinting() && !alice.isSwimming()
                && !alice.isInvisible() && !alice.isGlowing() && !alice.isGliding();
            if (!matches) {
                if (r.tick % 100 == 0) r.event("player_sync_mismatch", "x", alice.getX(), "y", alice.getY(), "z", alice.getZ(),
                    "yaw", alice.getYaw(), "head_yaw", alice.getHeadYaw(), "body_yaw", alice.getBodyYaw(), "sneaking", alice.isSneaking());
                return;
            }
            if (syncObservedTick < 0) {
                syncObservedTick = r.tick;
                double dx = alice.getX() - client.player.getX();
                double dz = alice.getZ() - client.player.getZ();
                double dy = alice.getY() + 0.8 - client.player.getEyeY();
                client.player.setYaw((float) Math.toDegrees(Math.atan2(-dx, dz)));
                client.player.setPitch((float) -Math.toDegrees(Math.atan2(dy, Math.hypot(dx, dz))));
                return;
            }
            if (r.tick - syncObservedTick < 5) return;
            writeSync(r.peer + ".sync", alice.getX(), alice.getY(), alice.getZ(), alice.getYaw(), alice.getHeadYaw(), alice.getBodyYaw(), alice.isSneaking());
            r.event("player_sync_observed", "x", alice.getX(), "y", alice.getY(), "z", alice.getZ(), "yaw", alice.getYaw(),
                "head_yaw", alice.getHeadYaw(), "body_yaw", alice.getBodyYaw(), "sneaking", alice.isSneaking());
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
