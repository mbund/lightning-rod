package dev.lightningrod.e2e;

import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.HashMap;
import java.util.Map;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.function.Consumer;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.codec.StreamCodec;
import net.minecraft.network.protocol.common.custom.CustomPacketPayload;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayNetworking;

final class TestClient {
    record Message(String text) implements CustomPacketPayload {
        static final Type<Message> TYPE = new Type<>(GameApi.fixtureChannel());
        static final StreamCodec<RegistryFriendlyByteBuf, Message> CODEC = StreamCodec.of(
            (buffer, message) -> buffer.writeBytes(message.text().getBytes(StandardCharsets.UTF_8)),
            buffer -> {
                if (buffer.readableBytes() == 0 || buffer.readableBytes() > 4096)
                    throw new IllegalArgumentException("invalid fixture message size");
                return new Message(buffer.readCharSequence(buffer.readableBytes(), StandardCharsets.UTF_8).toString());
            });
        Message {
            int length = text.getBytes(StandardCharsets.UTF_8).length;
            if (length == 0 || length > 4096) throw new IllegalArgumentException("invalid fixture message size");
        }
        @Override public Type<Message> type() { return TYPE; }
    }

    private final Recorder recorder;
    private final Consumer<Message> sender;
    private String pendingPass;
    private final Map<String, Recorder.Capture> screenshots = new HashMap<>();
    private final Set<String> marks = new HashSet<>();
    private final Set<String> sentMarks = new HashSet<>();
    private final LinkedHashSet<String> messages = new LinkedHashSet<>();

    TestClient(Recorder recorder) { this(recorder, ClientPlayNetworking::send); }
    TestClient(Recorder recorder, Consumer<Message> sender) {
        this.recorder = recorder;
        this.sender = sender;
    }

    static void register() {
        PayloadApi.register();
        ClientPlayNetworking.registerGlobalReceiver(Message.TYPE, (message, context) -> {
            Recorder recorder = Recorder.instance();
            if (recorder.fixture == null) return;
            TestClient client = recorder.fixture.client;
            String text = message.text();
            client.receive(text);
        });
    }

    void receive(String text) {
        recorder.event("fixture_received", "message", text);
        if (text.startsWith("mark ")) {
            rememberMark(text.substring(5));
            if (pendingPass != null) pass(pendingPass);
        } else {
            if (messages.size() == 1024 && !messages.contains(text))
                throw new IllegalStateException("fixture message capacity exceeded");
            messages.addLast(text);
            recorder.fixture.message(text);
        }
    }

    void pass(String reason) {
        if (recorder.completed) return;
        if (!marks.containsAll(sentMarks)) {
            pendingPass = reason;
            return;
        }
        pendingPass = null;
        recorder.pass(reason);
    }
    boolean completing() { return pendingPass != null; }
    void fail(String reason) {
        pendingPass = null;
        recorder.fail(reason);
    }
    void event(String name, Object... fields) { recorder.event(name, fields); }
    void marker(String name) { recorder.marker(name); }
    boolean hasMarker(String name) { return java.nio.file.Files.exists(recorder.artifacts.resolve(name)); }
    void reconnect() {
        if (!recorder.protocolPhase.equals("disconnected")) throw new IllegalStateException("reconnect requires a disconnected client");
        recorder.connectionAttempted = false;
    }
    void restartStream() { recorder.restartStream(); }
    long streamTarget(int loaded) { return recorder.streamTarget(loaded); }
    // Checkpoint names identify a capture across fixture ticks, just like fence names.
    Recorder.Capture screenshot(String name) {
        Recorder.Capture capture = screenshots.get(name);
        if (capture != null) return capture;
        if (screenshots.size() == 256) throw new IllegalStateException("screenshot capacity exceeded");
        capture = recorder.checkpoint(name);
        screenshots.put(name, capture);
        return capture;
    }
    void send(String message) {
        sender.accept(new Message(message));
        recorder.event("fixture_sent", "message", message);
    }
    void reload() { send("reload"); }
    void mark(String name) {
        if (!sentMarks.contains(name)) {
            if (name.isEmpty() || name.getBytes(StandardCharsets.UTF_8).length > 128)
                throw new IllegalArgumentException("invalid fixture marker");
            if (sentMarks.size() == 256) throw new IllegalStateException("fixture marker capacity exceeded");
            sentMarks.add(name);
            send("mark " + name);
        }
    }
    private void rememberMark(String name) {
        if (name.isEmpty() || name.getBytes(StandardCharsets.UTF_8).length > 128)
            throw new IllegalArgumentException("invalid fixture marker");
        if (!marks.contains(name) && marks.size() == 256)
            throw new IllegalStateException("fixture marker capacity exceeded");
        marks.add(name);
    }
    boolean marked(String name) { return marks.contains(name); }
    boolean received(String message) { return messages.contains(message); }
    String value(String prefix) {
        return messages.stream().filter(message -> message.startsWith(prefix))
            .map(message -> message.substring(prefix.length())).reduce((before, after) -> after).orElse(null);
    }
    void broadcast(String message) { send("broadcast " + message); }
    void fence(String name) { messages.remove("fence " + name); send("fence " + name); }
    void durable(String name) { messages.remove("fence " + name); send("durable " + name); }
    boolean fenced(String name) { return received("fence " + name); }
}
