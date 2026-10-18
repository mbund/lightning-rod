package dev.lightningrod.e2e;

import java.util.List;
import net.minecraft.client.Minecraft;

final class CommandsFixture extends Fixture {
    private enum Phase { PERMISSIONS, CUSTOM_COMPLETION, MODE_COMPLETION, EXECUTION, HELP_FIRST, HELP_SECOND, REVOKE, REVOKED_TREE, DENIED, COMPLETE }
    private Phase phase = Phase.PERMISSIONS;
    private java.util.concurrent.CompletableFuture<com.mojang.brigadier.suggestion.Suggestions> commandSuggestions;

    CommandsFixture(Recorder r) { super(r); }

    public void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0) return;
        if (r.tick - r.terrainTick > 300) { client.fail("commands_timeout_stage_" + phase); return; }
        var handler = game.getConnection();
        var dispatcher = handler.getCommands();
        var root = dispatcher.getRoot().getChild("probe");
        if (root == null) return;
        boolean alice = r.peer.equals("alice");
        if (phase == Phase.PERMISSIONS) {
            if ((root.getChild("admin") != null) != alice) { client.fail("command_tree_permission_leak"); return; }
            if (root.getChild("disabled") != null) { client.fail("conditional_command_registered"); return; }
            String input = "probe choose a";
            commandSuggestions = dispatcher.getCompletionSuggestions(dispatcher.parse(input, handler.getSuggestionsProvider()));
            phase = Phase.CUSTOM_COMPLETION;
        }
        if (phase == Phase.CUSTOM_COMPLETION && commandSuggestions.isDone()) {
            var result = commandSuggestions.join();
            var names = result.getList().stream().map(value -> value.getText()).toList();
            if (!names.equals(List.of("alpha", "amber")) || result.getRange().getStart() != 13 || result.getRange().getEnd() != 14
                || result.getList().stream().anyMatch(value -> value.getTooltip() == null || !value.getTooltip().getString().startsWith("Custom target:"))) {
                client.fail("incorrect_custom_completion_" + names); return;
            }
            client.event("custom_completions_verified", "matches", names.toString(), "start", result.getRange().getStart());
            commandSuggestions = dispatcher.getCompletionSuggestions(dispatcher.parse("probe mode s", handler.getSuggestionsProvider()));
            phase = Phase.MODE_COMPLETION;
        }
        if (phase == Phase.MODE_COMPLETION && commandSuggestions.isDone()) {
            var names = commandSuggestions.join().getList().stream().map(value -> value.getText()).toList();
            if (!names.equals(List.of("survival"))) { client.fail("enum_completion_failed"); return; }
            handler.sendCommand("probe choose alpha 3");
            handler.sendCommand("probe choose alpha 99");
            handler.sendCommand("probe echo hello world");
            handler.sendCommand("probe admin secret");
            phase = Phase.EXECUTION;
        }
        if (phase == Phase.EXECUTION) {
            if (!r.receivedChat.contains("choice alpha=3") || !r.receivedChat.contains("hello world")
                || r.receivedChat.stream().noneMatch(text -> text.startsWith("Invalid argument."))) return;
            if (alice ? !r.receivedChat.contains("secret granted") : r.receivedChat.stream().noneMatch(text -> text.startsWith("Unknown command or insufficient permission"))) return;
            if (!alice && r.receivedChat.contains("secret granted")) { client.fail("unauthorized_handler_executed"); return; }
            handler.sendCommand("help");
            phase = Phase.HELP_FIRST;
        }
        if (phase == Phase.HELP_FIRST && r.receivedChat.contains("Next: /help 2")) {
            if (!alice && r.receivedChat.stream().anyMatch(text -> text.contains("SECRET_PERMISSION"))) { client.fail("help_permission_leak"); return; }
            if (!client.screenshot("command_help_first_page").done()) return;
            handler.sendCommand("help 2");
            phase = Phase.HELP_SECOND;
        }
        if (phase == Phase.HELP_SECOND && r.receivedChat.stream().anyMatch(text -> text.startsWith("Commands — page 2/"))) {
            if (r.receivedChat.stream().noneMatch(text -> text.contains("/probe choose <target> <amount>"))) { client.fail("help_arguments_missing"); return; }
            if (!client.screenshot("command_help_second_page").done()) return;
            client.mark(r.peer + ".commands-checked");
            phase = Phase.REVOKE;
        }
        if (phase == Phase.REVOKE) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".commands-checked")) return;
            if (alice) handler.sendCommand("probe admin revoke");
            phase = Phase.REVOKED_TREE;
        }
        if (phase == Phase.REVOKED_TREE && root.getChild("admin") == null) {
            if (alice && !r.receivedChat.contains("access revoked")) return;
            r.receivedChat.clear();
            handler.sendCommand("probe admin secret");
            phase = Phase.DENIED;
        }
        if (phase == Phase.DENIED && r.receivedChat.stream().anyMatch(text -> text.startsWith("Unknown command or insufficient permission"))) {
            if (r.receivedChat.contains("secret granted")) { client.fail("revoked_command_executed"); return; }
            client.mark(r.peer + ".commands-revoked");
            phase = Phase.COMPLETE;
        }
        if (phase == Phase.COMPLETE) {
            for (String other : r.expectedPeers) if (!client.marked(other + ".commands-revoked")) return;
            client.pass("typed_commands_completions_permissions_and_paginated_help");
        }
    }

}
