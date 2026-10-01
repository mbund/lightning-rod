package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ServerData;

final class LoginFixture extends Fixture {
    private final net.minecraft.client.multiplayer.ServerStatusPinger pinger = new net.minecraft.client.multiplayer.ServerStatusPinger();
    private ServerData pingInfo;

    LoginFixture(Recorder r) { super(r); }

    @Override public void tick(Minecraft client, int loaded, int missing) {
        if (r.terrainTick < 0) return;
        if (pingInfo == null) {
            pingInfo = new ServerData("Status probe", r.server, ServerData.Type.OTHER);
            try { StatusApi.ping(pinger, pingInfo); }
            catch (java.net.UnknownHostException error) { r.fail(client, "status_dns_failed"); }
        }
        pinger.tick();
        if (pingInfo.players != null) {
            r.event("server_status", "online", pingInfo.players.online(), "maximum", pingInfo.players.max(), "description", pingInfo.motd.getString());
            if (pingInfo.players.online() != 1 || pingInfo.players.max() < 1 ||
                (r.scenario.equals("status-plugin") ? !pingInfo.motd.getString().equals("E2E Vanilla Status") : pingInfo.motd.getString().isBlank()))
                r.fail(client, "incorrect_server_status");
            else r.pass(client, "login_terrain_and_live_status_received");
            pinger.removeAll();
        }

    }
}
