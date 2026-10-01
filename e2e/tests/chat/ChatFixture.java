package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;

final class ChatFixture extends Fixture {
    private boolean chatSent;
    private boolean chatInvalid;
    private long chatWalkTick = -1;
    private boolean readyPublished;

    ChatFixture(Recorder r) { super(r); }

    public void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0 || loaded < 9) return;
        if (GuiApi.screen(client) != null) GuiApi.screen(client, null);
        if (chatWalkTick < 0) {
            chatWalkTick = r.tick;
            client.player.setYRot(r.peer.equals(r.expectedPeers.getFirst()) ? 90 : -90);
            client.player.setXRot(45);
            client.options.keyUp.setDown(true);
        }
        if (r.tick - chatWalkTick < 10) return;
        client.options.keyUp.setDown(false);
        if (!readyPublished) {
            r.marker(r.peer + ".chat-ready");
            readyPublished = true;
        }
        if (!chatSent && r.expectedPeers.stream().allMatch(value -> Files.exists(r.artifacts.resolve(value + ".chat-ready")))) {
            client.getConnection().sendChat("e2e-chat:" + r.peer + ":short");
            client.getConnection().sendChat("e2e-chat:" + r.peer + ":" + "\u2603".repeat(200));
            chatSent = true;
            r.event("chat_sent");
        }
        if (chatInvalid) r.fail(client, "chat_duplicate_or_reordered");
        else if (chatSent && r.receivedChat.size() == r.expectedPeers.size() * 2) {
            var roster = client.getConnection().getOnlinePlayers();
            boolean rosterReady = roster.size() == r.expectedPeers.size()
                    && r.expectedPeers.stream().allMatch(name -> roster.stream()
                    .anyMatch(entry -> ClientApi.profileName(entry.getProfile()).equals(name)));
            if (!rosterReady) return;
            r.event("roster_received", "players", roster.size());
            GuiApi.toasts(client).clear();
            client.options.keyPlayerList.setDown(true);
            r.pass(client, "shared_chat_and_roster_received_by_all_peers");
        }
    }

    @Override public void chat(String text) {
        for (String sender : r.expectedPeers) {
            String shortMessage = "<" + sender + "> e2e-chat:" + sender + ":short";
            String longMessage = "<" + sender + "> e2e-chat:" + sender + ":" + "\u2603".repeat(200);
            if (!text.equals(shortMessage) && !text.equals(longMessage)) continue;
            if (r.receivedChat.contains(text) || text.equals(longMessage) && !r.receivedChat.contains(shortMessage)) chatInvalid = true;
            r.receivedChat.add(text);
            r.event("chat_received", "sender", sender, "long", text.equals(longMessage));
        }
    }
}
