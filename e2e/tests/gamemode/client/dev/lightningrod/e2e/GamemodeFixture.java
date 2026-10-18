package dev.lightningrod.e2e;

import java.util.List;
import java.util.concurrent.CompletableFuture;
import net.minecraft.client.Minecraft;
import net.minecraft.world.level.GameType;
import com.mojang.brigadier.suggestion.Suggestions;

final class GamemodeFixture extends Fixture {
    private static final int BREAD_COUNT = 17;
    private enum Phase { PERMISSIONS, MODE_COMPLETIONS, PLAYER_COMPLETIONS, INVALID_ARGUMENTS, TRANSITIONS, CURSOR_SETUP, SURVIVAL_CURSOR, WAIT_CREATIVE, CREATIVE_CURSOR, WAIT_SURVIVAL, RECOVERED_CURSOR }
    private Phase phase = Phase.PERMISSIONS;
    private int transition;
    private boolean sent;
    private CompletableFuture<Suggestions> suggestions;
    private static final String[] COMMANDS = {
        "gamemode creative", "gamemode adventure bob", "gamemode spectator @a",
        "gamemode creative @a", "gamemode survival @s", "gamemode survival bob",
        "gamemode adventure", "gamemode survival @a"
    };
    private static final GameType[] ALICE = {
        GameType.CREATIVE, GameType.CREATIVE, GameType.SPECTATOR, GameType.CREATIVE,
        GameType.SURVIVAL, GameType.SURVIVAL, GameType.ADVENTURE, GameType.SURVIVAL
    };
    private static final GameType[] BOB = {
        GameType.SURVIVAL, GameType.ADVENTURE, GameType.SPECTATOR, GameType.CREATIVE,
        GameType.CREATIVE, GameType.SURVIVAL, GameType.SURVIVAL, GameType.SURVIVAL
    };

    GamemodeFixture(Recorder r) { super(r); }

    public void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0 || game.player == null) return;
        if (r.tick - r.terrainTick > 600) {
            client.fail("gamemode_timeout_" + phase + "_" + transition);
            return;
        }
        var handler = game.getConnection();
        var dispatcher = handler.getCommands();
        if (dispatcher.getRoot().getChild("help") == null || handler.getOnlinePlayers().size() != 2) return;
        boolean alice = r.peer.equals("alice");

        if (phase == Phase.PERMISSIONS) {
            if (!alice) game.player.setPos(3.5, 65, 0.5);
            game.player.setYRot(alice ? -90 : 90);
            game.player.setXRot(10);
            if ((dispatcher.getRoot().getChild("gamemode") != null) != alice) {
                client.fail("gamemode_permission_tree");
                return;
            }
            if (alice) {
                if (!client.marked("bob-denied")) return;
                suggestions = dispatcher.getCompletionSuggestions(dispatcher.parse("gamemode ", handler.getSuggestionsProvider()));
            } else handler.sendCommand("gamemode creative");
            phase = Phase.MODE_COMPLETIONS;
        }
        if (phase == Phase.MODE_COMPLETIONS) {
            if (!alice) {
                if (r.receivedChat.stream().noneMatch(text -> text.startsWith("Unknown command or insufficient permission"))) return;
                if (game.gameMode.getPlayerMode() != GameType.SURVIVAL) {
                    client.fail("gamemode_permission_bypass");
                    return;
                }
                client.mark("bob-denied");
                phase = Phase.TRANSITIONS;
            } else {
                if (!suggestions.isDone()) return;
                var names = suggestions.join().getList().stream().map(value -> value.getText()).sorted().toList();
                if (!names.equals(List.of("adventure", "creative", "spectator", "survival"))) {
                    client.fail("gamemode_completions_" + names);
                    return;
                }
                suggestions = dispatcher.getCompletionSuggestions(dispatcher.parse("gamemode creative b", handler.getSuggestionsProvider()));
                phase = Phase.PLAYER_COMPLETIONS;
            }
        }
        if (phase == Phase.PLAYER_COMPLETIONS && suggestions.isDone()) {
            if (!suggestions.join().getList().stream().map(value -> value.getText()).toList().equals(List.of("bob"))) {
                client.fail("gamemode_player_completion_" + suggestions.join().getList());
                return;
            }
            handler.sendCommand("gamemode 1");
            handler.sendCommand("gamemode Creative");
            phase = Phase.INVALID_ARGUMENTS;
        }
        if (phase == Phase.INVALID_ARGUMENTS) {
            if (r.receivedChat.stream().filter(text -> text.startsWith("Invalid argument.")).count() < 2 || !client.marked("bob-denied")) return;
            if (game.gameMode.getPlayerMode() != GameType.SURVIVAL) {
                client.fail("gamemode_invalid_mode_accepted");
                return;
            }
            phase = Phase.TRANSITIONS;
        }
        if (switch (phase) { case CURSOR_SETUP, SURVIVAL_CURSOR, WAIT_CREATIVE, CREATIVE_CURSOR, WAIT_SURVIVAL, RECOVERED_CURSOR -> true; default -> false; }) {
            if (alice) {
                if (phase == Phase.CURSOR_SETUP && client.marked("bob-holding")) {
                    handler.sendCommand("gamemode creative bob");
                    phase = Phase.WAIT_CREATIVE;
                }
                if (phase == Phase.WAIT_CREATIVE && client.marked("bob-creative-cursor")) {
                    handler.sendCommand("gamemode survival bob");
                    phase = Phase.WAIT_SURVIVAL;
                }
                if (phase == Phase.WAIT_SURVIVAL && client.marked("bob-cursor-recovered"))
                    client.pass("gamemode_permissions_completion_abilities_and_replication");
                return;
            }
            if (phase == Phase.CURSOR_SETUP) {
                if (game.player.getInventory().getItem(0).getCount() != BREAD_COUNT) {
                    client.fail("gamemode_inventory_setup");
                    return;
                }
                GuiApi.screen(game, new net.minecraft.client.gui.screens.inventory.InventoryScreen(game.player));
                GameApi.inventoryClick(game, 36, 0, ClickType.PICKUP);
                client.fence("gamemode-survival-cursor");
                phase = Phase.SURVIVAL_CURSOR;
            }
            if (phase == Phase.SURVIVAL_CURSOR && client.fenced("gamemode-survival-cursor")) {
                if (game.player.containerMenu.getCarried().getCount() != BREAD_COUNT) {
                    client.fail("gamemode_survival_cursor_setup");
                    return;
                }
                client.mark("bob-holding");
                phase = Phase.WAIT_CREATIVE;
            }
            if (phase == Phase.WAIT_CREATIVE && game.gameMode.getPlayerMode() == GameType.CREATIVE) {
                client.fence("gamemode-creative-cursor");
                phase = Phase.CREATIVE_CURSOR;
            }
            if (phase == Phase.CREATIVE_CURSOR && client.fenced("gamemode-creative-cursor")) {
                client.mark("bob-creative-cursor");
                phase = Phase.WAIT_SURVIVAL;
            }
            if (phase == Phase.WAIT_SURVIVAL && game.gameMode.getPlayerMode() == GameType.SURVIVAL) {
                game.player.closeContainer();
                client.fence("gamemode-recovered-cursor");
                phase = Phase.RECOVERED_CURSOR;
            }
            if (phase == Phase.RECOVERED_CURSOR && client.fenced("gamemode-recovered-cursor")) {
                int bread = game.player.containerMenu.getCarried().getCount();
                for (int slot = 0; slot < 46; slot++) bread += game.player.inventoryMenu.getSlot(slot).getItem().getCount();
                if (bread != BREAD_COUNT || !game.player.containerMenu.getCarried().isEmpty()) {
                    client.fail("gamemode_cursor_loss_or_duplication_" + bread);
                    return;
                }
                if (!client.screenshot("gamemode_cursor_recovered").done()) return;
                client.mark("bob-cursor-recovered");
                client.pass("gamemode_transitions_and_cursor_ownership");
            }
            return;
        }
        if (phase != Phase.TRANSITIONS) return;

        if (transition == COMMANDS.length) {
            phase = Phase.CURSOR_SETUP;
            return;
        }
        String marker = r.peer + "-gamemode-" + transition;
        if (client.marked(marker)) {
            for (String peer : r.expectedPeers)
                if (!client.marked(peer + "-gamemode-" + transition)) return;
            transition++;
            sent = false;
            return;
        }
        if (!sent) {
            if (alice) {
                handler.sendCommand(COMMANDS[transition] + (transition == 6 ? " " + game.player.getStringUUID() : ""));
                client.fence("gamemode-" + transition);
            }
            sent = true;
        }
        var expected = alice ? ALICE[transition] : BOB[transition];
        if (game.gameMode.getPlayerMode() != expected) return;
        if (alice ? !client.fenced("gamemode-" + transition) : !client.marked("alice-gamemode-" + transition)) return;
        if (game.level.players().size() != 2) return;
        for (var entry : handler.getOnlinePlayers()) {
            var mode = ClientApi.profileName(entry.getProfile()).equals("alice") ? ALICE[transition] : BOB[transition];
            if (entry.getGameMode() != mode) return;
        }
        var abilities = game.player.getAbilities();
        boolean canFly = expected == GameType.CREATIVE || expected == GameType.SPECTATOR;
        boolean flying = expected == GameType.SPECTATOR || expected == GameType.CREATIVE && transition >= 3;
        if (abilities.mayfly != canFly || abilities.invulnerable != canFly
            || abilities.instabuild != (expected == GameType.CREATIVE) || abilities.flying != flying
            || abilities.mayBuild != (expected == GameType.CREATIVE || expected == GameType.SURVIVAL)) {
            client.fail("gamemode_abilities_" + transition);
            return;
        }
        for (var player : game.level.players()) {
            if (player == game.player) continue;
            boolean spectator = (alice ? BOB[transition] : ALICE[transition]) == GameType.SPECTATOR;
            if (player.isSpectator() != spectator || player.isInvisible() != spectator) return;
        }
        if (!client.marked(marker)) {
            if (!client.screenshot("gamemode_" + transition + "_" + expected.toString()).done()) return;
            client.event("gamemode_verified", "transition", transition, "mode", expected.toString());
            client.mark(marker);
        }
        for (String peer : r.expectedPeers)
            if (!client.marked(peer + "-gamemode-" + transition)) return;
        transition++;
        sent = false;
    }
}
