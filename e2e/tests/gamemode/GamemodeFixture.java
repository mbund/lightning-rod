package dev.lightningrod.e2e;

import java.nio.file.Files;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import net.minecraft.client.Minecraft;
import net.minecraft.world.level.GameType;
import com.mojang.brigadier.suggestion.Suggestions;

final class GamemodeFixture extends Fixture {
    private int stage;
    private int transition;
    private long sentAt;
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

    public void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0 || client.player == null) return;
        if (r.tick - r.terrainTick > 600) {
            r.fail(client, "gamemode_timeout_" + stage + "_" + transition);
            return;
        }
        var handler = client.getConnection();
        var dispatcher = handler.getCommands();
        if (dispatcher.getRoot().getChild("help") == null || handler.getOnlinePlayers().size() != 2) return;
        boolean alice = r.peer.equals("alice");

        if (stage == 0) {
            if (!alice) client.player.setPos(3.5, 65, 0.5);
            client.player.setYRot(alice ? -90 : 90);
            client.player.setXRot(10);
            if ((dispatcher.getRoot().getChild("gamemode") != null) != alice) {
                r.fail(client, "gamemode_permission_tree");
                return;
            }
            if (alice) {
                if (!Files.exists(r.artifacts.resolve("bob-denied"))) return;
                suggestions = dispatcher.getCompletionSuggestions(dispatcher.parse("gamemode ", handler.getSuggestionsProvider()));
            } else handler.sendCommand("gamemode creative");
            stage = 1;
        }
        if (stage == 1) {
            if (!alice) {
                if (r.receivedChat.stream().noneMatch(text -> text.startsWith("Unknown command or insufficient permission"))) return;
                if (client.gameMode.getPlayerMode() != GameType.SURVIVAL) {
                    r.fail(client, "gamemode_permission_bypass");
                    return;
                }
                r.marker("bob-denied");
                stage = 4;
            } else {
                if (!suggestions.isDone()) return;
                var names = suggestions.join().getList().stream().map(value -> value.getText()).sorted().toList();
                if (!names.equals(List.of("adventure", "creative", "spectator", "survival"))) {
                    r.fail(client, "gamemode_completions_" + names);
                    return;
                }
                suggestions = dispatcher.getCompletionSuggestions(dispatcher.parse("gamemode creative b", handler.getSuggestionsProvider()));
                stage = 2;
            }
        }
        if (stage == 2 && suggestions.isDone()) {
            if (!suggestions.join().getList().stream().map(value -> value.getText()).toList().equals(List.of("bob"))) {
                r.fail(client, "gamemode_player_completion_" + suggestions.join().getList());
                return;
            }
            handler.sendCommand("gamemode 1");
            handler.sendCommand("gamemode Creative");
            stage = 3;
        }
        if (stage == 3) {
            if (r.receivedChat.stream().filter(text -> text.startsWith("Invalid argument.")).count() < 2 || !Files.exists(r.artifacts.resolve("bob-denied"))) return;
            if (client.gameMode.getPlayerMode() != GameType.SURVIVAL) {
                r.fail(client, "gamemode_invalid_mode_accepted");
                return;
            }
            stage = 4;
        }
        if (stage >= 5) {
            if (alice) {
                if (stage == 5 && Files.exists(r.artifacts.resolve("bob-holding"))) {
                    handler.sendCommand("gamemode creative bob");
                    stage = 6;
                }
                if (stage == 6 && Files.exists(r.artifacts.resolve("bob-creative-cursor"))) {
                    handler.sendCommand("gamemode survival bob");
                    stage = 7;
                }
                if (stage == 7 && Files.exists(r.artifacts.resolve("bob-cursor-recovered")))
                    r.pass(client, "gamemode_permissions_completion_abilities_and_replication");
                return;
            }
            if (stage == 5) {
                if (client.player.getInventory().getItem(0).getCount() != 17) {
                    r.fail(client, "gamemode_inventory_setup");
                    return;
                }
                GuiApi.screen(client, new net.minecraft.client.gui.screens.inventory.InventoryScreen(client.player));
                GameApi.inventoryClick(client, 36, 0, ClickType.PICKUP);
                sentAt = r.tick;
                stage = 6;
            }
            if (stage == 6 && r.tick - sentAt >= 10) {
                if (client.player.containerMenu.getCarried().getCount() != 17) {
                    r.fail(client, "gamemode_survival_cursor_setup");
                    return;
                }
                r.marker("bob-holding");
                stage = 7;
            }
            if (stage == 7 && client.gameMode.getPlayerMode() == GameType.CREATIVE) {
                sentAt = r.tick;
                stage = 8;
            }
            if (stage == 8 && r.tick - sentAt >= 10) {
                r.marker("bob-creative-cursor");
                stage = 9;
            }
            if (stage == 9 && client.gameMode.getPlayerMode() == GameType.SURVIVAL) {
                client.player.closeContainer();
                sentAt = r.tick;
                stage = 10;
            }
            if (stage == 10 && r.tick - sentAt >= 10) {
                int bread = client.player.containerMenu.getCarried().getCount();
                for (int slot = 0; slot < 46; slot++) bread += client.player.inventoryMenu.getSlot(slot).getItem().getCount();
                if (bread != 17 || !client.player.containerMenu.getCarried().isEmpty()) {
                    r.fail(client, "gamemode_cursor_loss_or_duplication_" + bread);
                    return;
                }
                r.screenshot(client, "gamemode_cursor_recovered");
                r.marker("bob-cursor-recovered");
                r.pass(client, "gamemode_transitions_and_cursor_ownership");
            }
            return;
        }
        if (stage != 4) return;

        if (transition == COMMANDS.length) {
            stage = 5;
            return;
        }
        String marker = r.peer + "-gamemode-" + transition;
        if (Files.exists(r.artifacts.resolve(marker))) {
            for (String peer : r.expectedPeers)
                if (!Files.exists(r.artifacts.resolve(peer + "-gamemode-" + transition))) return;
            transition++;
            sent = false;
            return;
        }
        if (!sent) {
            if (alice) handler.sendCommand(COMMANDS[transition] + (transition == 6 ? " " + client.player.getStringUUID() : ""));
            sentAt = r.tick;
            sent = true;
        }
        var expected = alice ? ALICE[transition] : BOB[transition];
        if (client.gameMode.getPlayerMode() != expected || r.tick - sentAt < 5) return;
        if (client.level.players().size() != 2) return;
        for (var entry : handler.getOnlinePlayers()) {
            var mode = ClientApi.profileName(entry.getProfile()).equals("alice") ? ALICE[transition] : BOB[transition];
            if (entry.getGameMode() != mode) return;
        }
        var abilities = client.player.getAbilities();
        boolean canFly = expected == GameType.CREATIVE || expected == GameType.SPECTATOR;
        boolean flying = expected == GameType.SPECTATOR || expected == GameType.CREATIVE && transition >= 3;
        if (abilities.mayfly != canFly || abilities.invulnerable != canFly
            || abilities.instabuild != (expected == GameType.CREATIVE) || abilities.flying != flying
            || abilities.mayBuild != (expected == GameType.CREATIVE || expected == GameType.SURVIVAL)) {
            r.fail(client, "gamemode_abilities_" + transition);
            return;
        }
        for (var player : client.level.players()) {
            if (player == client.player) continue;
            boolean spectator = (alice ? BOB[transition] : ALICE[transition]) == GameType.SPECTATOR;
            if (player.isSpectator() != spectator || player.isInvisible() != spectator) return;
        }
        if (!Files.exists(r.artifacts.resolve(marker))) {
            r.event("gamemode_verified", "transition", transition, "mode", expected.toString());
            r.screenshot(client, "gamemode_" + transition + "_" + expected.toString());
            r.marker(marker);
        }
        for (String peer : r.expectedPeers)
            if (!Files.exists(r.artifacts.resolve(peer + "-gamemode-" + transition))) return;
        transition++;
        sent = false;
    }
}
