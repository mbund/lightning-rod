package dev.mbund.lightningrod.vanillaharness;

import io.netty.channel.ChannelFutureListener;
import net.minecraft.network.ClientConnection;
import net.minecraft.network.DisconnectionInfo;
import net.minecraft.network.NetworkSide;
import net.minecraft.network.listener.PacketListener;
import net.minecraft.network.packet.Packet;
import net.minecraft.network.state.NetworkState;
import net.minecraft.text.Text;

import java.net.InetSocketAddress;
import java.net.SocketAddress;

/** A Vanilla connection whose transport terminates at the harness boundary. */
final class HarnessConnection extends ClientConnection {
    private final HarnessController controller;
    private final String alias;
    private boolean open = true;

    HarnessConnection(HarnessController controller, String alias) {
        super(NetworkSide.SERVERBOUND);
        this.controller = controller;
        this.alias = alias;
    }

    @Override
    public <T extends PacketListener> void transitionInbound(NetworkState<T> state, T listener) {
        // The harness invokes the bound Vanilla codec directly. There is no
        // Netty pipeline to transition.
    }

    @Override
    public void transitionOutbound(NetworkState<?> state) {
        // Output is encoded directly by HarnessController.capture.
    }

    @Override
    public void send(Packet<?> packet) {
        controller.capture(alias, packet);
    }

    @Override
    public void send(Packet<?> packet, ChannelFutureListener listener) {
        controller.capture(alias, packet);
    }

    @Override
    public void send(Packet<?> packet, ChannelFutureListener listener, boolean flush) {
        controller.capture(alias, packet);
    }

    @Override
    public void flush() {}

    @Override
    public void tick() {}

    @Override
    public boolean isOpen() {
        return open;
    }

    @Override
    public boolean isChannelAbsent() {
        return false;
    }

    @Override
    public boolean isLocal() {
        return false;
    }

    @Override
    public SocketAddress getAddress() {
        return new InetSocketAddress("127.0.0.1", 0);
    }

    @Override
    public String getAddressAsString(boolean logIps) {
        return "harness:" + alias;
    }

    @Override
    public void disconnect(Text reason) {
        open = false;
    }

    @Override
    public void disconnect(DisconnectionInfo info) {
        open = false;
    }
}
