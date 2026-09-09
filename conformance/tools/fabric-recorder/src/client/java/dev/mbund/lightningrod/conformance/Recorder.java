package dev.mbund.lightningrod.conformance;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import net.minecraft.client.MinecraftClient;

/** Raw, unframed packet capture. Zig owns all decoding and assertions. */
public final class Recorder {
    private static final Recorder INSTANCE = new Recorder();
    private final List<String> packets = new ArrayList<>();
    private Path output;
    private String peer = "client";
    private long tick;
    private boolean enabled;
    private boolean written;
    public static Recorder instance() { return INSTANCE; }
    public void configure() {
        String value = System.getProperty("mcc.output");
        if (value == null || value.isBlank()) return;
        output = Path.of(value); peer = System.getProperty("mcc.peer", peer); enabled = true;
    }
    public synchronized void inboundRaw(byte[] bytes) { record("clientbound", bytes); }
    public synchronized void outboundRaw(byte[] bytes) { record("serverbound", bytes); }
    public synchronized void advance() { if (enabled && !written) tick++; }
    private void record(String direction, byte[] bytes) {
        if (enabled && !written) packets.add("packet " + tick + " " + direction + " " + peer + " " + HexFormat.of().formatHex(bytes));
    }
    public synchronized void write(MinecraftClient client) {
        if (!enabled || written) return;
        written = true;
        try {
            if (output.getParent() != null) Files.createDirectories(output.getParent());
            List<String> document = new ArrayList<>(); document.add("mcc-capture-v1"); document.add("minecraft 1.21.8");
            if (client.world != null) client.world.getPlayers().forEach(player -> document.add("identity " + player.getGameProfile().getName() + " " + player.getId()));
            document.addAll(packets);
            Files.writeString(output, String.join("\n", document) + "\n", StandardCharsets.UTF_8);
        } catch (IOException error) { throw new IllegalStateException("cannot write conformance capture", error); }
    }
}
