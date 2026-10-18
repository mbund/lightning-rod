package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;

final class ChatFixture extends Fixture {
    private boolean chatSent;
    private boolean receiptsPublished;
    private boolean drainRequested;
    private boolean walking;
    private double startX;
    private boolean readyPublished;

    ChatFixture(Recorder r) { super(r); }

    public void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || loaded < 9) return;
        if (GuiApi.screen(game) != null) GuiApi.screen(game, null);
        if (!walking) {
            walking = true;
            startX = game.player.getX();
            game.player.setYRot(r.peer.equals(r.expectedPeers.getFirst()) ? 90 : -90);
            game.player.setXRot(45);
            game.options.keyUp.setDown(true);
        }
        if (Math.abs(game.player.getX() - startX) < 1) return;
        game.options.keyUp.setDown(false);
        if (!readyPublished) {
            client.mark(r.peer + ".chat-ready");
            readyPublished = true;
        }
        if (!chatSent && r.expectedPeers.stream().allMatch(value -> client.marked(value + ".chat-ready"))) {
            game.getConnection().sendChat("e2e-chat:" + r.peer + ":short");
            game.getConnection().sendChat("e2e-chat:" + r.peer + ":" + "\u2603".repeat(200));
            chatSent = true;
            client.event("chat_sent");
        }
        if (chatSent && r.receivedChat.size() == r.expectedPeers.size() * 2) {
            var roster = game.getConnection().getOnlinePlayers();
            boolean rosterReady = roster.size() == r.expectedPeers.size()
                    && r.expectedPeers.stream().allMatch(name -> roster.stream()
                    .anyMatch(entry -> ClientApi.profileName(entry.getProfile()).equals(name)));
            if (!rosterReady) return;
            if (!receiptsPublished) {
                client.mark(r.peer + ".chat-received");
                receiptsPublished = true;
            }
            for (String peer : r.expectedPeers) if (!client.marked(peer + ".chat-received")) return;
            if (!drainRequested) {
                client.send("chat_drain");
                drainRequested = true;
            }
            if (!client.received("chat_drained")) return;
            client.event("roster_received", "players", roster.size());
            GuiApi.toasts(game).clear();
            game.options.keyPlayerList.setDown(true);
            client.pass("shared_chat_and_roster_received_by_all_peers");
        }
    }

    @Override public void chat(String text) {
        for (String sender : r.expectedPeers) {
            String shortMessage = "<" + sender + "> e2e-chat:" + sender + ":short";
            String longMessage = "<" + sender + "> e2e-chat:" + sender + ":" + "\u2603".repeat(200);
            if (!text.equals(shortMessage) && !text.equals(longMessage)) continue;
            if (r.receivedChat.contains(text) || text.equals(longMessage) && !r.receivedChat.contains(shortMessage)) client.fail("chat_duplicate_or_reordered");
            r.receivedChat.add(text);
            client.event("chat_received", "sender", sender, "long", text.equals(longMessage));
        }
    }
}
