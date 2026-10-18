package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ServerData;
import net.minecraft.client.multiplayer.ServerStatusPinger;
import net.minecraft.core.component.DataComponents;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;

final class ProtocolFixture extends Fixture {
    // Matches Players.Configuration.render_distance in main.zig.
    private static final int RENDER_DISTANCE = 2;
    private static final int CHUNK_DIAMETER = 2 * RENDER_DISTANCE + 1;
    private static final int EXPECTED_CHUNKS = CHUNK_DIAMETER * CHUNK_DIAMETER;
    private final ServerStatusPinger pinger = new ServerStatusPinger();
    private ServerData status;
    private boolean positioned;
    private boolean itemSent;
    private boolean reloadRequested;
    private boolean verifiedReload;
    private volatile int configurations;

    ProtocolFixture(Recorder recorder) { super(recorder); }

    @Override public void reconfigurationEncoded() { configurations++; }

    private ItemStack item(Minecraft game) {
        var stack = new ItemStack(Items.DIAMOND_SHOVEL);
        stack.set(DataComponents.CUSTOM_NAME, net.minecraft.network.chat.Component.literal("Downstream item"));
        stack.set(DataComponents.LORE, new net.minecraft.world.item.component.ItemLore(java.util.List.of(net.minecraft.network.chat.Component.literal("Downstream lore"))));
        return stack;
    }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (verifiedReload) {
            String other = r.peer.equals("alice") ? "bob" : "alice";
            if (client.marked("rendered-" + other))
                client.pass("custom_bootstrap_negotiation_play_and_reload");
            return;
        }
        if (r.terrainTick < 0 || loaded < EXPECTED_CHUNKS) return;
        if (!GameApi.dimension(game).equals("example:world")
            || game.level.getMinY() != -64 || game.level.getHeight() != 384) {
            client.fail("custom_dimension_not_selected");
            return;
        }
        if (!positioned) {
            boolean alice = r.peer.equals("alice");
            game.player.setPos(alice ? -3.5 : 3.5, 65, 0.5);
            game.player.setYRot(alice ? -90 : 90);
            game.player.setXRot(10);
            positioned = true;
            return;
        }
        if (!itemSent) {
            var stack = item(game);
            game.player.getInventory().setSelectedSlot(0);
            game.player.getInventory().setItem(0, stack);
            game.gameMode.handleCreativeModeItemAdd(stack, 36);
            itemSent = true;
            return;
        }
        if (!game.player.getMainHandItem().getHoverName().getString().equals("Downstream item")) return;
        for (var player : game.level.players()) {
            var held = player.getMainHandItem();
            if (held.getHoverName().getString().equals("Downstream item") &&
                !ItemStack.isSameItemSameComponents(held, item(game))) {
                client.fail("custom_component_registry_mistranslated");
                return;
            }
        }
        if (status == null) {
            if (game.level.players().stream().noneMatch(player -> player != game.player && player.distanceToSqr(game.player) > 4)) return;
            if (game.getConnection().getOnlinePlayers().size() != 2) return;
            if (game.level.players().stream().noneMatch(player -> player != game.player && player.getMainHandItem().getHoverName().getString().equals("Downstream item"))) return;
            status = new ServerData("Custom protocol", r.server, ServerData.Type.OTHER);
            try { StatusApi.ping(pinger, status); }
            catch (java.net.UnknownHostException error) { client.fail("status_dns_failed"); return; }
        }
        pinger.tick();
        if (status.players == null) return;
        if (status.protocol != 9001 || status.players.online() != 2)
            client.fail("custom_protocol_not_selected");
        else {
            client.mark("protocol-" + r.peer);
            String other = r.peer.equals("alice") ? "bob" : "alice";
            if (!client.marked("protocol-" + other)) return;
            if (!reloadRequested && r.peer.equals("alice")) {
                client.reload();
                reloadRequested = true;
            }
            if (configurations == 0) return;
            var center = game.player.chunkPosition();
            for (int z = (center.getMinBlockZ() >> 4) - RENDER_DISTANCE; z <= (center.getMinBlockZ() >> 4) + RENDER_DISTANCE; z++)
                for (int x = (center.getMinBlockX() >> 4) - RENDER_DISTANCE; x <= (center.getMinBlockX() >> 4) + RENDER_DISTANCE; x++) {
                    if (game.level.getChunkSource().getChunk(x, z, net.minecraft.world.level.chunk.status.ChunkStatus.FULL, false) == null) return;
                    if (!game.level.getBlockState(new net.minecraft.core.BlockPos(x * 16, 64, z * 16)).is(net.minecraft.world.level.block.Blocks.GRASS_BLOCK)) {
                        client.fail("custom_protocol_missing_terrain");
                        return;
                    }
                    if (!game.level.getBiome(new net.minecraft.core.BlockPos(x * 16, 64, z * 16)).is(net.minecraft.world.level.biome.Biomes.PLAINS)) {
                        client.fail("custom_protocol_biome_registry_mistranslated");
                        return;
                    }
                }
            if (!game.levelRenderer.hasRenderedAllSections()) return;
            if (game.level.players().stream().noneMatch(player -> player != game.player && player.getMainHandItem().getHoverName().getString().equals("Downstream item"))) return;
            if (game.getConnection().getOnlinePlayers().size() != 2) return;
            client.mark("rendered-" + r.peer);
            verifiedReload = true;
            if (!client.marked("rendered-" + other)) return;
            client.pass("custom_bootstrap_negotiation_play_and_reload");
        }
        pinger.removeAll();
    }
}
