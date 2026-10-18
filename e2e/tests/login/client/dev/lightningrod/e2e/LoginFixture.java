package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ServerData;

final class LoginFixture extends Fixture {
    private final net.minecraft.client.multiplayer.ServerStatusPinger pinger = new net.minecraft.client.multiplayer.ServerStatusPinger();
    private ServerData pingInfo;

    LoginFixture(Recorder r) { super(r); }

    @Override public void tick(Minecraft game, int loaded, int missing) {
        if (r.terrainTick < 0) return;
        if (pingInfo == null) {
            pingInfo = new ServerData("Status probe", r.server, ServerData.Type.OTHER);
            try { StatusApi.ping(pinger, pingInfo); }
            catch (java.net.UnknownHostException error) { client.fail("status_dns_failed"); return; }
        }
        pinger.tick();
        if (pingInfo.players != null) {
            client.event("server_status", "online", pingInfo.players.online(), "maximum", pingInfo.players.max(), "description", pingInfo.motd.getString());
            if (pingInfo.players.online() != 1 || pingInfo.players.max() < 1 ||
                (r.scenario.equals("status-plugin") ? !pingInfo.motd.getString().equals("E2E Vanilla Status") : pingInfo.motd.getString().isBlank()))
                client.fail("incorrect_server_status");
            else client.pass("login_terrain_and_live_status_received");
            pinger.removeAll();
        }

    }
}
