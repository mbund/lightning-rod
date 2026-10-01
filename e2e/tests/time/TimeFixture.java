package dev.lightningrod.e2e;

import java.nio.file.Files;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import com.mojang.brigadier.suggestion.Suggestions;
import net.minecraft.client.Minecraft;
import net.minecraft.network.protocol.game.ServerboundMovePlayerPacket;

final class TimeFixture extends Fixture {
    private record Case(String command, long time, String reply) {}
    private static final Case[] CASES = {
        new Case("time set day", 1000, "Set the time to 1000"),
        new Case("time set noon", 6000, "Set the time to 6000"),
        new Case("time set night", 13000, "Set the time to 13000"),
        new Case("time set midnight", 18000, "Set the time to 18000"),
        new Case("time set 1.5d", 36000, "Set the time to 36000"),
        new Case("time add 0.5s", 36010, "Set the time to 12010"),
        new Case("time add .5t", 36011, "Set the time to 12011"),
        new Case("time query daytime", 36011, "The time is 12011"),
        new Case("time query day", 36011, "The time is 1"),
        new Case("time query gametime", 36011, "The time is "),
        new Case("time set -1", 36011, "Invalid argument."),
        new Case("time add 1e3", 36011, "Invalid argument."),
        new Case("time set 1h", 36011, "Invalid argument."),
        new Case("time set NaN", 36011, "Invalid argument."),
        new Case("time set noon extra", 36011, "Unknown command or insufficient permission"),
        new Case("time add day", 36011, "Invalid argument."),
        new Case("time set 1", 1, "Set the time to 1"),
        new Case("time add -.5t", 1, "Set the time to 1"),
        new Case("time set 999999999999999d", 2147483647, "Set the time to 2147483647"),
        new Case("time set day", 1000, "Set the time to 1000")
    };
    private static final String[] COMPLETIONS = {"time ", "time set n", "time add 1", "time query "};
    private static final List<List<String>> EXPECTED = List.of(
        List.of("add", "query", "set"), List.of("night", "noon"),
        List.of("1d", "1s", "1t"), List.of("day", "daytime", "gametime"));

    private int stage;
    private int completion;
    private int current;
    private boolean sent;
    private long sentAt;
    private long age;
    private CompletableFuture<Suggestions> suggestions;

    TimeFixture(Recorder r) { super(r); }

    @Override void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0 || client.player == null || client.level == null || GuiApi.screen(client) != null) return;
        if (r.tick - r.terrainTick > 1200) { r.fail(client, "time_timeout_" + stage + "_" + current); return; }
        var handler = client.getConnection();
        var dispatcher = handler.getCommands();
        if (dispatcher.getRoot().getChild("help") == null || handler.getOnlinePlayers().size() != 2) return;
        boolean alice = r.peer.equals("alice");

        if (stage == 0) {
            if ((dispatcher.getRoot().getChild("time") != null) != alice) { r.fail(client, "time_permission_tree"); return; }
            double x = alice ? -2.5 : 2.5;
            client.player.setPos(x, 65, 0.5);
            client.player.setYRot(0);
            client.player.setXRot(-15);
            handler.send(new ServerboundMovePlayerPacket.PosRot(x, 65, 0.5, 0, -15, true, false));
            age = client.level.getGameTime();
            if (!alice) handler.sendCommand("time set midnight");
            stage = 1;
        }
        if (stage == 1) {
            if (!alice) {
                if (r.receivedChat.stream().noneMatch(text -> text.startsWith("Unknown command or insufficient permission"))) return;
                if (GameApi.dayTime(client) != 0) { r.fail(client, "time_permission_bypass"); return; }
                r.marker("time-denied");
                stage = 3;
            } else {
                if (!Files.exists(r.artifacts.resolve("time-denied"))) return;
                stage = 2;
            }
        }
        if (stage == 2) {
            if (suggestions == null) suggestions = dispatcher.getCompletionSuggestions(dispatcher.parse(COMPLETIONS[completion], handler.getSuggestionsProvider()));
            if (!suggestions.isDone()) return;
            var names = suggestions.join().getList().stream().map(value -> value.getText()).sorted().toList();
            if (!names.equals(EXPECTED.get(completion))) { r.fail(client, "time_completion_" + completion + "_" + names); return; }
            r.event("time_completion_verified", "input", COMPLETIONS[completion], "results", names.toString());
            suggestions = null;
            if (++completion < COMPLETIONS.length) return;
            stage = 3;
        }
        if (stage == 3) {
            Case test = CASES[current];
            if (!sent) {
                r.receivedChat.clear();
                sentAt = r.tick;
                if (alice) handler.sendCommand(test.command());
                sent = true;
            }
            String marker = "time-case-" + current;
            if (!Files.exists(r.artifacts.resolve(r.peer + "." + marker))) {
                if (alice && r.receivedChat.stream().noneMatch(text -> text.startsWith(test.reply()))) return;
                if (GameApi.dayTime(client) != test.time() || r.tick - sentAt < 5) return;
                if (alice && test.command().equals("time query gametime")) {
                    String reply = r.receivedChat.stream().filter(text -> text.startsWith(test.reply())).findFirst().orElseThrow();
                    long value = Long.parseLong(reply.substring(test.reply().length()));
                    if (Math.abs(value - client.level.getGameTime()) > 100) { r.fail(client, "time_query_age"); return; }
                }
                if (current == 3 || current == CASES.length - 1) {
                    if (!client.levelRenderer.hasRenderedAllSections()) return;
                    r.screenshot(client, current == 3 ? "midnight" : "day");
                }
                r.event("time_command_verified", "command", test.command(), "time", GameApi.dayTime(client));
                r.marker(r.peer + "." + marker);
            }
            for (String peer : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(peer + "." + marker))) return;
            sent = false;
            if (++current < CASES.length) return;
            if (alice) handler.sendCommand("reload");
            stage = 4;
        }
        if (stage == 4 && r.joins == 2 && GameApi.dayTime(client) == 1000 && client.level.players().size() == 2) {
            if (client.level.getGameTime() <= age) { r.fail(client, "time_game_age_stopped"); return; }
            r.screenshot(client, "time_after_reload");
            r.marker(r.peer + ".time-reloaded");
            stage = 5;
        }
        if (stage == 5) {
            for (String peer : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(peer + ".time-reloaded"))) return;
            r.pass(client, "time_permissions_completions_units_queries_sync_and_reload");
        }
    }
}
