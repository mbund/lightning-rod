package dev.lightningrod.e2e;

import java.nio.file.Files;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ServerData;
import net.minecraft.client.multiplayer.ServerStatusPinger;
import net.minecraft.core.component.DataComponents;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;

final class ProtocolFixture extends Fixture {
    private final ServerStatusPinger pinger = new ServerStatusPinger();
    private ServerData status;
    private boolean positioned;
    private boolean itemSent;
    private boolean reloadRequested;
    private boolean verifiedReload;
    private volatile int configurations;

    ProtocolFixture(Recorder recorder) { super(recorder); }

    @Override public void reconfigurationEncoded() { configurations++; }

    private ItemStack item(Minecraft client) {
        var stack = new ItemStack(Items.DIAMOND_SHOVEL);
        stack.set(DataComponents.CUSTOM_NAME, net.minecraft.network.chat.Component.literal("Downstream item"));
        stack.set(DataComponents.LORE, new net.minecraft.world.item.component.ItemLore(java.util.List.of(net.minecraft.network.chat.Component.literal("Downstream lore"))));
        return stack;
    }

    @Override public void tick(Minecraft client, int loaded, int missing) {
        if (verifiedReload) {
            String other = r.peer.equals("alice") ? "bob" : "alice";
            if (Files.exists(r.artifacts.resolve("rendered-" + other)))
                r.pass(client, "custom_bootstrap_negotiation_play_and_reload");
            return;
        }
        if (r.terrainTick < 0 || loaded < 81) return;
        if (!GameApi.dimension(client).equals("example:world")
            || client.level.getMinY() != -64 || client.level.getHeight() != 384) {
            r.fail(client, "custom_dimension_not_selected");
            return;
        }
        if (!positioned) {
            boolean alice = r.peer.equals("alice");
            client.player.setPos(alice ? -3.5 : 3.5, 65, 0.5);
            client.player.setYRot(alice ? -90 : 90);
            client.player.setXRot(10);
            positioned = true;
            return;
        }
        if (!itemSent) {
            var stack = item(client);
            client.player.getInventory().setSelectedSlot(0);
            client.player.getInventory().setItem(0, stack);
            client.gameMode.handleCreativeModeItemAdd(stack, 36);
            itemSent = true;
            return;
        }
        if (!client.player.getMainHandItem().getHoverName().getString().equals("Downstream item")) return;
        for (var player : client.level.players()) {
            var held = player.getMainHandItem();
            if (held.getHoverName().getString().equals("Downstream item") &&
                !ItemStack.isSameItemSameComponents(held, item(client))) {
                r.fail(client, "custom_component_registry_mistranslated");
                return;
            }
        }
        if (status == null) {
            if (client.level.players().stream().noneMatch(player -> player != client.player && player.distanceToSqr(client.player) > 4)) return;
            if (client.getConnection().getOnlinePlayers().size() != 2) return;
            if (client.level.players().stream().noneMatch(player -> player != client.player && player.getMainHandItem().getHoverName().getString().equals("Downstream item"))) return;
            status = new ServerData("Custom protocol", r.server, ServerData.Type.OTHER);
            try { StatusApi.ping(pinger, status); }
            catch (java.net.UnknownHostException error) { r.fail(client, "status_dns_failed"); }
        }
        pinger.tick();
        if (status.players == null) return;
        if (status.protocol != 9001 || status.players.online() != 2)
            r.fail(client, "custom_protocol_not_selected");
        else {
            r.marker("protocol-" + r.peer);
            String other = r.peer.equals("alice") ? "bob" : "alice";
            if (!Files.exists(r.artifacts.resolve("protocol-" + other))) return;
            if (!reloadRequested && r.peer.equals("alice")) {
                client.getConnection().sendCommand("protocol_reload");
                reloadRequested = true;
            }
            if (configurations == 0) return;
            var center = client.player.chunkPosition();
            for (int z = (center.getMinBlockZ() >> 4) - 4; z <= (center.getMinBlockZ() >> 4) + 4; z++)
                for (int x = (center.getMinBlockX() >> 4) - 4; x <= (center.getMinBlockX() >> 4) + 4; x++) {
                    if (client.level.getChunkSource().getChunk(x, z, net.minecraft.world.level.chunk.status.ChunkStatus.FULL, false) == null) return;
                    if (!client.level.getBlockState(new net.minecraft.core.BlockPos(x * 16, 64, z * 16)).is(net.minecraft.world.level.block.Blocks.GRASS_BLOCK)) {
                        r.fail(client, "custom_protocol_missing_terrain");
                        return;
                    }
                }
            if (!client.levelRenderer.hasRenderedAllSections()) return;
            if (client.level.players().stream().noneMatch(player -> player != client.player && player.getMainHandItem().getHoverName().getString().equals("Downstream item"))) return;
            if (client.getConnection().getOnlinePlayers().size() != 2) return;
            r.marker("rendered-" + r.peer);
            verifiedReload = true;
            if (!Files.exists(r.artifacts.resolve("rendered-" + other))) return;
            r.pass(client, "custom_bootstrap_negotiation_play_and_reload");
        }
        pinger.removeAll();
    }
}
