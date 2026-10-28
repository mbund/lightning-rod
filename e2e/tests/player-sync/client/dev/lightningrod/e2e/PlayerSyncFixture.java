package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.util.Mth;

final class PlayerSyncFixture extends Fixture {
    private boolean syncStarted;
    private boolean syncPublished;
    private boolean syncStopped;
    private boolean viewPrepared;
    private double syncStartX;

    PlayerSyncFixture(Recorder r) { super(r); }

    public void tick(Minecraft game, int loaded, int missing) {
        if (loaded < 9 || r.terrainTick < 0 || missing != 0) return;
        if (!client.marked(r.peer + ".sync-ready")) {
            if (!r.peer.equals("alice")) game.player.setPos(0.5, 65, 3.5 + 2 * r.expectedPeers.indexOf(r.peer));
            client.mark(r.peer + ".sync-ready");
        }
        for (String peer : r.expectedPeers) if (!client.marked(peer + ".sync-ready")) return;
        if (r.peer.equals("alice")) {
            if (!syncStarted) {
                if (missing != 0) return;
                syncStartX = game.player.getX();
                game.player.setYRot(90.0f);
                game.player.setYHeadRot(90.0f);
                game.player.setYBodyRot(90.0f);
                game.options.keyShift.setDown(true);
                if (!client.screenshot("player_sync_alice_input").done()) return;
                syncStarted = true;
                game.options.keyUp.setDown(true);
                client.event("player_sync_input", "yaw", 90.0f, "sneaking", true);
            }
            if (!syncStopped && syncStartX - game.player.getX() >= 1) {
                game.options.keyUp.setDown(false);
                syncStopped = true;
            }
            if (!syncPublished && syncStopped && game.player.getDeltaMovement().horizontalDistanceSqr() < 0.00000001) {
                syncPublished = true;
                publish("alice", game.player.getX(), game.player.getY(), game.player.getZ(),
                    game.player.getYRot(), game.player.getYHeadRot(), game.player.getVisualRotationYInDegrees(), game.player.isShiftKeyDown());
                client.event("player_sync_published", "x", game.player.getX(), "y", game.player.getY(), "z", game.player.getZ(),
                    "yaw", game.player.getYRot(), "head_yaw", game.player.getYHeadRot(), "body_yaw", game.player.getVisualRotationYInDegrees(), "sneaking", game.player.isShiftKeyDown());
            }
            if (syncPublished && r.expectedPeers.stream().allMatch(peer -> client.marked(peer + ".sync-observed"))) {
                client.pass("player_state_observed_by_peers");
            }
            return;
        }
        String value = client.value("sync alice ");
        if (value == null) return;
        var alice = game.level.players().stream()
            .filter(player -> ClientApi.profileName(player.getGameProfile()).equals("alice"))
            .findFirst().orElse(null);
        if (alice == null) return;
        try {
            String[] expected = value.trim().split(" ");
            if (expected.length != 7) { client.fail("player_sync_expectation_invalid"); return; }
            boolean matches = close(alice.getX(), Double.parseDouble(expected[0]), 0.05)
                && close(alice.getY(), Double.parseDouble(expected[1]), 0.05)
                && close(alice.getZ(), Double.parseDouble(expected[2]), 0.05)
                && angleClose(alice.getYRot(), Float.parseFloat(expected[3]))
                && angleClose(alice.getYHeadRot(), Float.parseFloat(expected[4]))
                // LivingEntity.turnHead derives body yaw locally and clamps it to 50 degrees from view yaw.
                && Math.abs(Mth.wrapDegrees(alice.getYRot() - alice.getVisualRotationYInDegrees())) <= 50.01f
                && alice.isShiftKeyDown() == Boolean.parseBoolean(expected[6])
                && alice.getPose() == net.minecraft.world.entity.Pose.CROUCHING
                && !alice.isOnFire() && !alice.isSprinting() && !alice.isSwimming()
                && !alice.isInvisible() && !alice.isCurrentlyGlowing() && !alice.isFallFlying();
            if (!matches) {
                if (r.tick % 100 == 0) client.event("player_sync_mismatch", "x", alice.getX(), "y", alice.getY(), "z", alice.getZ(),
                    "yaw", alice.getYRot(), "head_yaw", alice.getYHeadRot(), "body_yaw", alice.getVisualRotationYInDegrees(), "sneaking", alice.isShiftKeyDown());
                return;
            }
            if (!viewPrepared) {
                viewPrepared = true;
                double dx = alice.getX() - game.player.getX();
                double dz = alice.getZ() - game.player.getZ();
                double dy = alice.getY() + 0.8 - game.player.getEyeY();
                game.player.setYRot((float) Math.toDegrees(Math.atan2(-dx, dz)));
                game.player.setXRot((float) -Math.toDegrees(Math.atan2(dy, Math.hypot(dx, dz))));
                return;
            }
            if (!client.screenshot("player_sync_observed").done()) return;
            client.mark(r.peer + ".sync-observed");
            client.event("player_sync_observed", "x", alice.getX(), "y", alice.getY(), "z", alice.getZ(), "yaw", alice.getYRot(),
                "head_yaw", alice.getYHeadRot(), "body_yaw", alice.getVisualRotationYInDegrees(), "sneaking", alice.isShiftKeyDown());
            client.pass("replicated_position_rotation_and_sneak_state");
        } catch (NumberFormatException error) {
            client.fail("player_sync_expectation_unreadable");
        }
    }

    private void publish(String name, double x, double y, double z, float yaw, float headYaw, float bodyYaw, boolean sneaking) {
        client.broadcast(String.format(java.util.Locale.ROOT, "sync %s %f %f %f %f %f %f %s", name, x, y, z, yaw, headYaw, bodyYaw, sneaking));
        client.mark(name + ".sync-observed");
    }
}
