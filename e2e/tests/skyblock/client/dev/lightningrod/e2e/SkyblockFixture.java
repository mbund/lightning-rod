package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Blocks;

final class SkyblockFixture extends Fixture {
    private enum Phase { HUB, CREATE, VISITOR, KICKED, INVITED, MEMBER, RETURN, HOME, VERIFY, DONE }
    private Phase phase = Phase.HUB;
    private boolean sent;
    private boolean verified;
    private String invitation;
    private String visitRequest;
    private boolean visitAccepted;

    SkyblockFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }
    @Override boolean canConnect() { return !r.peer.equals("bob") || marked("alice.created"); }

    @Override void chatAction(String text, String command, String hover) {
        if (text.equals("Invitation from alice. [Accept]")) {
            if (!command.equals("/is accept alice")) client.fail("wrong_invitation_action");
            if (!"Click to join this island and make it your home.".equals(hover)) client.fail("wrong_invitation_tooltip");
            invitation = command;
        }
        if (text.equals("bob wants to visit your island. [Accept]")) {
            if (!command.equals("/visit accept bob")) client.fail("wrong_visit_action");
            if (!"Click to let this player visit your island.".equals(hover)) client.fail("wrong_visit_tooltip");
            visitRequest = command;
        }
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || loaded < 9 || GuiApi.screen(game) != null) return;
        if (r.peer.equals("alice")) alice(game);
        else bob(game);
    }

    private void alice(Minecraft game) {
        if (phase == Phase.HUB) {
            checkHub(game);
            if (!client.screenshot("hub").done()) return;
            command(game, "is create");
            phase = Phase.CREATE;
        }
        if (phase == Phase.CREATE) {
            if (r.joins != 2 || !heard("Island created. Travelling home.")) return;
            checkIsland(game);
            if (!client.screenshot("owner_island").done()) return;
            if (!sent) { r.marker("alice.created"); sent = true; }
            if (!marked("bob.hub") || !heard("bob joined the game")) return;
            game.getConnection().sendChat("hello from the island");
            phase = Phase.VISITOR;
        }
        if (phase == Phase.VISITOR) {
            if (!heard("<bob> hello from the hub")) return;
            if (!visitAccepted) {
                if (visitRequest == null) return;
                command(game, visitRequest.substring(1));
                visitAccepted = true;
            }
            if (!marked("bob.visiting") || game.level.players().size() != 2) return;
            if (!client.screenshot("visitor").done()) return;
            command(game, "kick bob");
            phase = Phase.KICKED;
        }
        if (phase == Phase.KICKED) {
            if (!heard("Visitor sent to hub.") || !marked("bob.kicked") || game.level.players().size() != 1) return;
            command(game, "is invite bob");
            phase = Phase.INVITED;
        }
        if (phase == Phase.INVITED) {
            if (!heard("Invitation sent.") || !marked("bob.member") || game.level.players().size() != 2) return;
            command(game, "kick bob");
            phase = Phase.MEMBER;
        }
        if (phase == Phase.MEMBER) {
            if (!heard("Island members cannot be kicked as visitors.")) return;
            r.marker("alice.membership-checked");
            if (!marked("bob.home")) return;
            command(game, "hub");
            phase = Phase.RETURN;
        }
        if (phase == Phase.RETURN) {
            if (r.joins != 3 || !heard("Returning to hub.")) return;
            if (!client.screenshot("owner_hub").done()) return;
            command(game, "visit bob");
            phase = Phase.HOME;
        }
        if (phase == Phase.HOME) {
            if (r.joins != 4 || game.level.players().size() != 2) return;
            phase = Phase.VERIFY;
        }
        finish("alice");
    }

    private void bob(Minecraft game) {
        if (phase == Phase.HUB) {
            if (!sent) {
                if (game.level.players().size() != 1) return;
                checkHub(game);
                r.marker("bob.hub");
                sent = true;
            }
            if (!marked("alice.created")) return;
            if (!heard("<alice> hello from the island")) return;
            game.getConnection().sendChat("hello from the hub");
            command(game, "visit alice");
            sent = false;
            phase = Phase.VISITOR;
        }
        if (phase == Phase.VISITOR) {
            if (r.joins != 2 || game.level.players().size() != 2) return;
            if (!sent) { command(game, "island"); sent = true; }
            if (!heard("No home island found.")) return;
            if (!client.screenshot("visiting_without_membership").done()) return;
            r.marker("bob.visiting");
            phase = Phase.KICKED;
        }
        if (phase == Phase.KICKED) {
            if (r.joins != 3 || game.level.players().size() != 1) return;
            r.marker("bob.kicked");
            if (invitation == null) return;
            command(game, invitation.substring(1));
            phase = Phase.INVITED;
        }
        if (phase == Phase.INVITED) {
            if (r.joins != 4 || !heard("Joined island. Travelling home.") || game.level.players().size() != 2) return;
            command(game, "island create");
            command(game, "island invite alice");
            command(game, "kick alice");
            phase = Phase.MEMBER;
        }
        if (phase == Phase.MEMBER) {
            long denied = r.receivedChat.stream().filter("Only the island owner can do that."::equals).count();
            if (!heard("You already belong to an island.") || denied != 2) return;
            r.marker("bob.member");
            if (!marked("alice.membership-checked")) return;
            command(game, "hub");
            phase = Phase.RETURN;
        }
        if (phase == Phase.RETURN) {
            if (r.joins != 5 || !heard("Returning to hub.")) return;
            command(game, "is");
            phase = Phase.HOME;
        }
        if (phase == Phase.HOME) {
            if (r.joins != 6) return;
            r.marker("bob.home");
            if (game.level.players().size() != 2) return;
            phase = Phase.VERIFY;
        }
        finish("bob");
    }

    private void finish(String peer) {
        if (phase == Phase.VERIFY) {
            long ownJoins = r.receivedChat.stream().filter((peer + " joined the game")::equals).count();
            if (ownJoins != 1) { client.fail("island_transfers_must_not_repeat_join_announcements"); return; }
            if (!heard("<alice> hello from the island") || !heard("<bob> hello from the hub")) {
                client.fail("cross_world_chat_missing");
                return;
            }
            if (!verified) {
                client.send("skyblock_member");
                client.fence("skyblock_verified");
                verified = true;
            }
            if (!client.fenced("skyblock_verified")) return;
            if (!client.screenshot("shared_home").done()) return;
            r.marker(peer + ".verified");
            phase = Phase.DONE;
        }
        if (phase == Phase.DONE && marked("alice.verified") && marked("bob.verified"))
            client.pass("skyblock_creation_visits_invitations_membership_and_hub_verified");
    }

    private void command(Minecraft game, String command) { game.getConnection().sendCommand(command); }
    private void checkHub(Minecraft game) {
        if (!game.level.getBlockState(new BlockPos(-4, 64, -4)).is(Blocks.STONE)
            || !game.level.getBlockState(new BlockPos(4, 64, 4)).is(Blocks.STONE)
            || !game.level.getBlockState(new BlockPos(5, 64, 0)).isAir()
            || !game.level.getBlockState(new BlockPos(0, 63, 0)).isAir())
            client.fail("hub_must_be_a_stone_platform_over_void");
    }
    private void checkIsland(Minecraft game) {
        if (game.level.getWorldBorder().getSize() != 512) client.fail("wrong_island_boundary");
        if (!game.level.getBlockState(new BlockPos(0, 64, 0)).is(Blocks.GRASS_BLOCK)
            || !game.level.getBlockState(new BlockPos(0, 62, 0)).is(Blocks.DIRT)
            || !game.level.getBlockState(new BlockPos(-2, 65, 1)).is(Blocks.OAK_LOG)
            || !game.level.getBlockState(new BlockPos(-2, 71, 1)).is(Blocks.OAK_LEAVES)
            || !game.level.getBlockState(new BlockPos(1, 65, -2)).is(Blocks.CHEST)
            || !game.level.getBlockState(new BlockPos(-1, 64, -1)).isAir()
            || !game.level.getBlockState(new BlockPos(0, 61, 0)).isAir()
            || !game.level.getBlockState(new BlockPos(8, 64, 8)).isAir())
            client.fail("island_must_be_classic_skyblock_over_void");
    }
    private boolean heard(String text) { return r.receivedChat.contains(text); }
    private boolean marked(String name) { return Files.exists(r.artifacts.resolve(name)); }
}
