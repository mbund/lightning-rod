package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;

final class JoinLeaveFixture extends Fixture {
    private enum Phase { JOIN, PEERS, RELOAD, DEPARTURE }
    private Phase phase = Phase.JOIN;

    JoinLeaveFixture(Recorder r) {
        super(r);
        if (r.peer.equals("bob")) r.connectTick = Integer.MAX_VALUE;
    }

    @Override void poll(Minecraft game) {
        if (r.peer.equals("bob") && Files.exists(r.artifacts.resolve("alice.join-ready")))
            r.connectTick = (int) r.tick;
    }

    @Override void chat(String text) {
        super.chat(text);
        client.event("chat_received", "text", text);
        long own = r.receivedChat.stream().filter(message -> message.equals(r.peer + " joined the game")).count();
        long bob = r.receivedChat.stream().filter(message -> message.equals("bob joined the game")).count();
        long left = r.receivedChat.stream().filter(message -> message.endsWith(" left the game")).count();
        if (own > 1 || bob > 1 || left > 1) client.fail("duplicate_join_or_leave");
        else if (left != 0 && phase != Phase.DEPARTURE) client.fail("spurious_leave_during_reload");
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || game.player == null || GuiApi.screen(game) != null) return;
        boolean alice = r.peer.equals("alice");
        long own = r.receivedChat.stream().filter(text -> text.equals(r.peer + " joined the game")).count();
        long bob = r.receivedChat.stream().filter(text -> text.equals("bob joined the game")).count();
        long left = r.receivedChat.stream().filter(text -> text.endsWith(" left the game")).count();

        if (phase == Phase.JOIN) {
            if (own != 1) return;
            client.mark(r.peer + ".join-ready");
            if (alice) r.marker("alice.join-ready");
            phase = Phase.PEERS;
        }
        if (phase == Phase.PEERS) {
            if (bob != 1 || game.level.players().size() != 2) return;
            for (String peer : r.expectedPeers)
                if (!client.marked(peer + ".join-ready")) return;
            if (!client.screenshot("joined").done()) return;
            client.mark(r.peer + ".joined-captured");
            for (String peer : r.expectedPeers)
                if (!client.marked(peer + ".joined-captured")) return;
            if (alice) client.reload();
            phase = Phase.RELOAD;
        }
        if (phase == Phase.RELOAD) {
            if (r.joins != 2 || game.level.players().size() != 2) return;
            client.mark(r.peer + ".reload-ready");
            phase = Phase.DEPARTURE;
        }
        if (phase == Phase.DEPARTURE) {
            for (String peer : r.expectedPeers)
                if (!client.marked(peer + ".reload-ready")) return;
            if (!alice) {
                client.pass("join_once_and_reload_without_join_or_leave");
                return;
            }
            if (left != 1 || !r.receivedChat.contains("bob left the game")) return;
            if (game.level.players().size() != 1) return;
            client.pass("join_broadcast_reload_suppression_and_departure");
        }
    }
}
