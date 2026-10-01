package dev.lightningrod.e2e;

import java.net.UnknownHostException;
import net.minecraft.client.multiplayer.ServerStatusPinger;
import net.minecraft.client.multiplayer.ServerData;

final class StatusApi {
    static void ping(ServerStatusPinger pinger, ServerData info) throws UnknownHostException {
        pinger.pingServer(info, () -> {}, () -> {});
    }
}
