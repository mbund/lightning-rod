package dev.lightningrod.e2e;

import java.nio.file.Files;
import java.util.List;
import net.minecraft.client.Minecraft;

final class CommandsFixture extends Fixture {
    private int itemsStage;
    private long itemsTick;
    private java.util.concurrent.CompletableFuture<com.mojang.brigadier.suggestion.Suggestions> commandSuggestions;

    CommandsFixture(Recorder r) { super(r); }

    public void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0) return;
        if (r.tick - r.terrainTick > 300) { r.fail(client, "commands_timeout_stage_" + itemsStage); return; }
        var handler = client.getConnection();
        var dispatcher = handler.getCommands();
        var root = dispatcher.getRoot().getChild("probe");
        if (root == null) return;
        boolean alice = r.peer.equals("alice");
        if (itemsStage == 0) {
            if ((root.getChild("admin") != null) != alice) { r.fail(client, "command_tree_permission_leak"); return; }
            if (root.getChild("disabled") != null) { r.fail(client, "conditional_command_registered"); return; }
            String input = "probe choose a";
            commandSuggestions = dispatcher.getCompletionSuggestions(dispatcher.parse(input, handler.getSuggestionsProvider()));
            itemsStage = 1;
        }
        if (itemsStage == 1 && commandSuggestions.isDone()) {
            var result = commandSuggestions.join();
            var names = result.getList().stream().map(value -> value.getText()).toList();
            if (!names.equals(List.of("alpha", "amber")) || result.getRange().getStart() != 13 || result.getRange().getEnd() != 14
                || result.getList().stream().anyMatch(value -> value.getTooltip() == null || !value.getTooltip().getString().startsWith("Custom target:"))) {
                r.fail(client, "incorrect_custom_completion_" + names); return;
            }
            r.event("custom_completions_verified", "matches", names.toString(), "start", result.getRange().getStart());
            commandSuggestions = dispatcher.getCompletionSuggestions(dispatcher.parse("probe mode s", handler.getSuggestionsProvider()));
            itemsStage = 2;
        }
        if (itemsStage == 2 && commandSuggestions.isDone()) {
            var names = commandSuggestions.join().getList().stream().map(value -> value.getText()).toList();
            if (!names.equals(List.of("survival"))) { r.fail(client, "enum_completion_failed"); return; }
            handler.sendCommand("probe choose alpha 3");
            handler.sendCommand("probe choose alpha 99");
            handler.sendCommand("probe echo hello world");
            handler.sendCommand("probe admin secret");
            itemsStage = 3;
        }
        if (itemsStage == 3) {
            if (!r.receivedChat.contains("choice alpha=3 / typed-environment") || !r.receivedChat.contains("hello world")
                || r.receivedChat.stream().noneMatch(text -> text.startsWith("Invalid argument."))) return;
            if (alice ? !r.receivedChat.contains("secret granted") : r.receivedChat.stream().noneMatch(text -> text.startsWith("Unknown command or insufficient permission"))) return;
            if (!alice && r.receivedChat.contains("secret granted")) { r.fail(client, "unauthorized_handler_executed"); return; }
            handler.sendCommand("help");
            itemsStage = 4;
        }
        if (itemsStage == 4 && r.receivedChat.contains("Next: /help 2")) {
            if (!alice && r.receivedChat.stream().anyMatch(text -> text.contains("SECRET_PERMISSION"))) { r.fail(client, "help_permission_leak"); return; }
            r.screenshot(client, "command_help_first_page");
            handler.sendCommand("help 2");
            itemsStage = 5;
        }
        if (itemsStage == 5 && r.receivedChat.stream().anyMatch(text -> text.startsWith("Commands — page 2/"))) {
            if (r.receivedChat.stream().noneMatch(text -> text.contains("/probe choose <target> <amount>"))) { r.fail(client, "help_arguments_missing"); return; }
            r.screenshot(client, "command_help_second_page");
            r.marker(r.peer + ".commands-checked");
            itemsStage = 6;
        }
        if (itemsStage == 6) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".commands-checked"))) return;
            if (alice) handler.sendCommand("probe admin revoke");
            itemsStage = 7;
        }
        if (itemsStage == 7 && root.getChild("admin") == null) {
            if (alice && !r.receivedChat.contains("access revoked")) return;
            r.receivedChat.clear();
            handler.sendCommand("probe admin secret");
            itemsStage = 8;
        }
        if (itemsStage == 8 && r.receivedChat.stream().anyMatch(text -> text.startsWith("Unknown command or insufficient permission"))) {
            if (r.receivedChat.contains("secret granted")) { r.fail(client, "revoked_command_executed"); return; }
            r.marker(r.peer + ".commands-revoked");
            itemsStage = 9;
        }
        if (itemsStage == 9) {
            for (String other : r.expectedPeers) if (!Files.exists(r.artifacts.resolve(other + ".commands-revoked"))) return;
            r.pass(client, "typed_commands_completions_permissions_and_paginated_help");
        }
    }

}
