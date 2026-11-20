package dev.lightningrod.e2e;

import java.nio.file.Files;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import net.minecraft.client.Minecraft;

/// Alice and bob sign everything they say: chat, a private message and an emote. Every line must
/// reach both of them as secure, as their clients judge it, before the server reloads and after,
/// when each client starts its chat over under a new session.
final class SecureChatFixture extends Fixture {
    private static final List<String> PEERS = List.of("alice", "bob");
    private static final String RELOAD = "player_reload";

    private final Set<String> secure = new HashSet<>();
    private final Map<String, UUID> sessions = new HashMap<>();
    private int round;
    private boolean sent;
    private boolean armed;
    private boolean reloadRequested;

    SecureChatFixture(Recorder r) { super(r); }

    @Override void playerChat(String text, String trust) {
        super.playerChat(text, trust);
        if (!trust.equals("SECURE")) {
            client.fail("chat_not_secure: " + trust + ": " + text);
            return;
        }
        secure.add(text);
    }

    /// What this client must have been shown by the end of the round.
    private Set<String> expected() {
        Set<String> lines = new HashSet<>();
        for (String peer : PEERS) lines.add("<" + peer + "> signed:" + peer + ":" + round);
        if (round == 0) {
            lines.add("* bob waves:" + round);
            lines.add(r.peer.equals("alice") ? "You whisper to bob: whisper:" + round : "alice whispers to you: whisper:" + round);
        }
        return lines;
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        var connection = game.getConnection();
        if (loaded < 9 || game.player == null || connection == null) return;
        // The reload sends each client a new login, and the next round begins.
        if (round == 0 && r.joins == 2) {
            if (!secure.containsAll(expected())) {
                client.fail("reload_before_round_finished");
                return;
            }
            round = 1;
            sent = false;
        }
        if (r.joins != round + 1) return;
        // Both players' keys must be known, and after the reload the new ones.
        for (String peer : PEERS) {
            var info = connection.getPlayerInfo(peer);
            var session = info == null ? null : info.getChatSession();
            if (session == null) return;
            UUID before = sessions.get(peer);
            if (round == 0) sessions.put(peer, session.sessionId());
            else if (session.sessionId().equals(before)) return;
        }
        String ready = ".signed-ready-" + round;
        if (!client.marked(r.peer + ready)) client.mark(r.peer + ready);
        if (!PEERS.stream().allMatch(peer -> client.marked(peer + ready))) return;
        if (!sent) {
            connection.sendChat("signed:" + r.peer + ":" + round);
            if (round == 0 && r.peer.equals("alice")) connection.sendCommand("msg bob whisper:" + round);
            if (round == 0 && r.peer.equals("bob")) connection.sendCommand("me waves:" + round);
            sent = true;
            client.event("signed_sent", "round", round);
        }
        if (!secure.containsAll(expected())) return;
        if (round == 1) {
            client.pass("signed_chat_secure_before_and_after_reload");
            return;
        }
        if (!armed) {
            r.marker(r.peer + ".reload-armed-" + RELOAD);
            armed = true;
        }
        if (r.peer.equals("alice") && !reloadRequested && Files.exists(r.artifacts.resolve("reload-request-" + RELOAD))) {
            connection.sendCommand("reload");
            reloadRequested = true;
        }
    }
}
