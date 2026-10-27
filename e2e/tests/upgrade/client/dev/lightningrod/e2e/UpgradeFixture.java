package dev.lightningrod.e2e;

import java.util.UUID;
import net.minecraft.client.Minecraft;
import net.minecraft.network.protocol.game.ServerboundMovePlayerPacket;

final class UpgradeFixture extends Fixture {
    private enum Phase { BEFORE, WAITING, RESUMED, REJECTED, RETRYING, COMPLETE }
    private final boolean newcomer;
    private Phase phase = Phase.BEFORE;
    private boolean positioned;
    private UUID identity;
    private UUID otherIdentity;
    private net.minecraft.network.Connection connection;

    UpgradeFixture(Recorder recorder) {
        super(recorder);
        newcomer = r.peer.equals("newcomer");
    }

    @Override boolean encrypted() { return true; }

    @Override void disconnected(Minecraft game, String title) {
        if (!newcomer || phase != Phase.BEFORE || r.joins != 0) {
            client.fail("unexpected_disconnect_during_upgrade");
            return;
        }
        phase = Phase.REJECTED;
        client.event("new_protocol_rejected", "title", title);
    }

    @Override void poll(Minecraft game) {
        if (phase != Phase.REJECTED) return;
        if (!client.screenshot("new_protocol_rejected").done()) return;
        if (!client.hasMarker(r.peer + ".upgrade-rejected")) client.marker(r.peer + ".upgrade-rejected");
        if (!client.hasMarker("upgrade.retry")) return;
        phase = Phase.RETRYING;
        client.reconnect();
    }

    @Override void chat(String text) {
        super.chat(text);
        if (text.startsWith("Reload rejected") || text.startsWith("Reload failed")) client.fail("upgrade_failed: " + text);
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (phase == Phase.COMPLETE) {
            for (String peer : r.expectedPeers) if (!client.hasMarker(peer + ".upgrade-verified")) return;
            client.pass(newcomer ? "new_protocol_rejected_before_upgrade_and_admitted_after"
                : "existing_encrypted_connection_survived_protocol_upgrade");
            return;
        }
        if (newcomer && phase != Phase.RETRYING) {
            client.fail("new_protocol_accepted_before_upgrade");
            return;
        }
        if (GuiApi.screen(game) != null || missingChunks(game, 2) != 0 || !game.player.onGround()) return;
        if (newcomer) {
            if (r.joins != 1) { client.fail("new_protocol_rejoined_unexpectedly"); return; }
            if (!allPlayersPresent(game, 3)) return;
            if (!client.screenshot("new_protocol_admitted").done()) return;
            client.marker(r.peer + ".upgrade-joined");
            client.marker(r.peer + ".upgrade-verified");
            phase = Phase.COMPLETE;
            return;
        }

        String otherName = r.peer.equals("alice") ? "bob" : "alice";
        double expectedX = r.peer.equals("alice") ? -3.5 : 3.5;
        double otherX = -expectedX;
        var other = game.level.players().stream().filter(player -> player.getName().getString().equals(otherName)).findFirst().orElse(null);
        if (other == null) return;
        if (phase == Phase.BEFORE) {
            if (r.joins != 1) { client.fail("upgrade_started_before_old_world_observed"); return; }
            if (!positioned) {
                identity = game.player.getUUID();
                otherIdentity = other.getUUID();
                connection = game.getConnection().getConnection();
                game.player.setPos(expectedX, 65, 3.5);
                game.player.setYRot(r.peer.equals("alice") ? -90 : 90);
                game.player.setXRot(0);
                game.getConnection().send(new ServerboundMovePlayerPacket.PosRot(expectedX, 65, 3.5, game.player.getYRot(), 0, true, false));
                game.getConnection().sendChat("upgrade-ready-" + r.peer);
                positioned = true;
            }
            if (!r.receivedChat.contains("<" + otherName + "> upgrade-ready-" + otherName)
                || !close(other.getX(), otherX, 0.01) || !close(other.getZ(), 3.5, 0.01)) return;
            if (!allPlayersPresent(game, 2)) return;
            if (!client.screenshot("before_upgrade").done()) return;
            client.marker(r.peer + ".upgrade-before");
            phase = Phase.WAITING;
        }
        if (phase == Phase.WAITING) {
            if (r.joins == 1) return;
            if (r.joins != 2) { client.fail("existing_connection_rejoined_unexpectedly"); return; }
            if (game.getConnection().getConnection() != connection) {
                client.fail("upgrade_replaced_existing_connection");
                return;
            }
            if (!game.player.getUUID().equals(identity) || !other.getUUID().equals(otherIdentity)) {
                client.fail("upgrade_changed_player_identity");
                return;
            }
            if (!close(game.player.getX(), expectedX, 0.01) || !close(game.player.getZ(), 3.5, 0.01)
                || !close(other.getX(), otherX, 0.01) || !close(other.getZ(), 3.5, 0.01)) return;
            if (!allPlayersPresent(game, 2)) return;
            if (!client.screenshot("after_upgrade").done()) return;
            client.marker(r.peer + ".upgrade-after");
            phase = Phase.RESUMED;
        }
        if (phase == Phase.RESUMED && client.hasMarker("newcomer.upgrade-joined")) {
            if (r.joins != 2) { client.fail("existing_connection_rejoined_unexpectedly"); return; }
            if (!allPlayersPresent(game, 3)) return;
            if (!client.screenshot("all_players_after_upgrade").done()) return;
            client.marker(r.peer + ".upgrade-verified");
            phase = Phase.COMPLETE;
        }
    }

    private boolean allPlayersPresent(Minecraft game, int expected) {
        if (game.level.players().size() != expected || game.getConnection().getOnlinePlayers().size() != expected) return false;
        for (String name : r.expectedPeers) {
            if (expected == 2 && name.equals("newcomer")) continue;
            if (game.level.players().stream().noneMatch(player -> player.getName().getString().equals(name))) return false;
        }
        return true;
    }
}
