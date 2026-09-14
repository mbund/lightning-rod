package dev.lightningrod.e2e;

import net.minecraft.client.MinecraftClient;
import net.minecraft.client.network.ServerInfo;

final class LoginFixture extends Fixture {
    private final net.minecraft.client.network.MultiplayerServerListPinger pinger = new net.minecraft.client.network.MultiplayerServerListPinger();
    private ServerInfo pingInfo;

    LoginFixture(Recorder r) { super(r); }

    @Override public void tick(MinecraftClient client, int loaded, int missing) {
        if (r.terrainTick < 0) return;
        if (pingInfo == null) {
            pingInfo = new ServerInfo("Status probe", r.server, ServerInfo.ServerType.OTHER);
            try { pinger.add(pingInfo, () -> {}, () -> {}); }
            catch (java.net.UnknownHostException error) { r.fail(client, "status_dns_failed"); }
        }
        pinger.tick();
        if (pingInfo.players != null) {
            r.event("server_status", "online", pingInfo.players.online(), "maximum", pingInfo.players.max(), "description", pingInfo.label.getString());
            if (pingInfo.players.online() != 1 || pingInfo.players.max() < 1 || pingInfo.label.getString().isBlank())
                r.fail(client, "incorrect_server_status");
            else r.pass(client, "login_terrain_and_live_status_received");
            pinger.cancel();
        }

    }
}
