package dev.lightningrod.e2e;

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

    private enum Phase { POSITION, PERMISSIONS, COMPLETIONS, COMMANDS, RELOAD, RELOADED }
    private Phase phase = Phase.POSITION;
    private int completion;
    private int current;
    private boolean sent;
    private long age;
    private CompletableFuture<Suggestions> suggestions;

    TimeFixture(Recorder r) { super(r); }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || game.player == null || game.level == null || GuiApi.screen(game) != null) return;
        if (r.tick - r.terrainTick > 1200) { client.fail("time_timeout_" + phase + "_" + current); return; }
        var handler = game.getConnection();
        var dispatcher = handler.getCommands();
        if (dispatcher.getRoot().getChild("help") == null || handler.getOnlinePlayers().size() != 2) return;
        boolean alice = r.peer.equals("alice");

        if (phase == Phase.POSITION) {
            if ((dispatcher.getRoot().getChild("time") != null) != alice) { client.fail("time_permission_tree"); return; }
            double x = alice ? -2.5 : 2.5;
            game.player.setPos(x, 65, 0.5);
            game.player.setYRot(0);
            game.player.setXRot(-15);
            handler.send(new ServerboundMovePlayerPacket.PosRot(x, 65, 0.5, 0, -15, true, false));
            age = game.level.getGameTime();
            if (!alice) handler.sendCommand("time set midnight");
            phase = Phase.PERMISSIONS;
        }
        if (phase == Phase.PERMISSIONS) {
            if (!alice) {
                if (r.receivedChat.stream().noneMatch(text -> text.startsWith("Unknown command or insufficient permission"))) return;
                if (GameApi.dayTime(game) != 0) { client.fail("time_permission_bypass"); return; }
                client.mark("time-denied");
                phase = Phase.COMMANDS;
            } else {
                if (!client.marked("time-denied")) return;
                phase = Phase.COMPLETIONS;
            }
        }
        if (phase == Phase.COMPLETIONS) {
            if (suggestions == null) suggestions = dispatcher.getCompletionSuggestions(dispatcher.parse(COMPLETIONS[completion], handler.getSuggestionsProvider()));
            if (!suggestions.isDone()) return;
            var names = suggestions.join().getList().stream().map(value -> value.getText()).sorted().toList();
            if (!names.equals(EXPECTED.get(completion))) { client.fail("time_completion_" + completion + "_" + names); return; }
            client.event("time_completion_verified", "input", COMPLETIONS[completion], "results", names.toString());
            suggestions = null;
            if (++completion < COMPLETIONS.length) return;
            phase = Phase.COMMANDS;
        }
        if (phase == Phase.COMMANDS) {
            Case test = CASES[current];
            if (!sent) {
                r.receivedChat.clear();
                if (alice) {
                    handler.sendCommand(test.command());
                    client.fence("time-case-" + current);
                }
                sent = true;
            }
            String marker = "time-case-" + current;
            if (!client.marked(r.peer + "." + marker)) {
                if (alice && r.receivedChat.stream().noneMatch(text -> text.startsWith(test.reply()))) return;
                if (GameApi.dayTime(game) != test.time() || !client.marked("alice.time-case-" + current) && !alice) return;
                if (alice && !client.fenced("time-case-" + current)) return;
                if (alice && test.command().equals("time query gametime")) {
                    String reply = r.receivedChat.stream().filter(text -> text.startsWith(test.reply())).findFirst().orElseThrow();
                    long value = Long.parseLong(reply.substring(test.reply().length()));
                    if (Math.abs(value - game.level.getGameTime()) > 100) { client.fail("time_query_age"); return; }
                }
                if (current == 3 || current == CASES.length - 1) {
                    if (!game.levelRenderer.hasRenderedAllSections()) return;
                    if (!client.screenshot(current == 3 ? "midnight" : "day").done()) return;
                }
                client.event("time_command_verified", "command", test.command(), "time", GameApi.dayTime(game));
                client.mark(r.peer + "." + marker);
            }
            for (String peer : r.expectedPeers) if (!client.marked(peer + "." + marker)) return;
            sent = false;
            if (++current < CASES.length) return;
            if (alice) client.reload();
            phase = Phase.RELOAD;
        }
        if (phase == Phase.RELOAD && r.joins == 2 && GameApi.dayTime(game) == 1000 && game.level.players().size() == 2) {
            if (game.level.getGameTime() <= age) { client.fail("time_game_age_stopped"); return; }
            if (!client.screenshot("time_after_reload").done()) return;
            client.mark(r.peer + ".time-reloaded");
            phase = Phase.RELOADED;
        }
        if (phase == Phase.RELOADED) {
            for (String peer : r.expectedPeers) if (!client.marked(peer + ".time-reloaded")) return;
            client.pass("time_permissions_completions_units_queries_sync_and_reload");
        }
    }
}
