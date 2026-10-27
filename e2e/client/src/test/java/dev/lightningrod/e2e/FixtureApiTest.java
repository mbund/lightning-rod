package dev.lightningrod.e2e;

import java.nio.file.Files;
import java.nio.file.Path;
import net.minecraft.client.Minecraft;

public final class FixtureApiTest {
    public static void main(String[] args) throws Exception {
        Recorder messages = new Recorder();
        messages.fixture = new Fixture(messages) {
            @Override void tick(Minecraft game, int loaded, int missing) {}
        };
        TestClient client = messages.fixture.client;
        client.receive("state A");
        client.receive("state B");
        client.receive("state A");
        require("A".equals(client.value("state ")), "repeated value must become latest");
        require(client.received("state B"), "previous messages must remain observable");
        for (int i = 2; i < 1024; i++) client.receive("state " + i);
        client.receive("state A");
        require("A".equals(client.value("state ")), "refresh must work at capacity");
        boolean rejected = false;
        try { client.receive("overflow"); }
        catch (IllegalStateException expected) { rejected = true; }
        require(rejected, "new messages must respect capacity");

        checkpoints();
        markerAcknowledgements();
        lateChatFailure(false);
        lateChatFailure(true);
        Recorder timing = new Recorder();
        timing.firstChunkTick = 7;
        timing.firstChunkNanos = 123;
        timing.tick = 20;
        timing.restartStream();
        require(timing.streamTarget(100) == 20, "target must record its first observation");
        timing.tick = 21;
        require(timing.streamTarget(101) == 20, "target must remain stable");
        timing.restartStream();
        require(timing.streamTarget(200) == 21, "a new stream must reset its target");
        require(timing.firstChunkTick == 7 && timing.firstChunkNanos == 123,
            "stream timing must preserve the original first chunk arrival");

        for (boolean passed : new boolean[]{false, true}) {
            for (boolean saved : new boolean[]{false, true}) {
                Path directory = Files.createTempDirectory("e2e-fixture-");
                Recorder recorder = new Recorder();
                recorder.artifacts = directory;
                try (var events = Files.newBufferedWriter(directory.resolve("events.jsonl"))) {
                    recorder.events = events;
                    recorder.screenshot("success");
                    recorder.screenshot("failure");
                    for (Recorder.Capture capture : recorder.pendingScreenshots) {
                        require(!capture.terminal(), "screenshot names must not imply completion");
                        recorder.captureFinished(capture, true);
                    }
                    recorder.pendingScreenshots.clear();
                    require(!recorder.resultPublished, "ordinary screenshots must not publish results");
                    if (passed) recorder.pass("assertion_passed");
                    else recorder.fail("assertion_failed");
                    Recorder.Capture terminal = recorder.pendingScreenshots.getFirst();
                    require(terminal.terminal(), "assertions must request a terminal capture");
                    recorder.captureFinished(terminal, saved);
                    String expected = !passed ? "FAIL assertion_failed\n" : saved
                        ? "PASS assertion_passed\n" : "FAIL terminal_screenshot_missing\n";
                    require(expected.equals(Files.readString(directory.resolve("client.result"))),
                        "capture completion must preserve assertion failures");
                    recorder.captureFinished(terminal, !saved);
                    require(expected.equals(Files.readString(directory.resolve("client.result"))),
                        "duplicate completion must not change the result");
                } finally {
                    try (var files = Files.list(directory)) {
                        for (Path file : files.toList()) Files.delete(file);
                    }
                    Files.delete(directory);
                }
            }
        }
    }

    private static void markerAcknowledgements() {
        Recorder recorder = new Recorder();
        var sent = new java.util.ArrayList<TestClient.Message>();
        TestClient client = new TestClient(recorder, sent::add);
        client.mark("first");
        client.mark("second");
        client.mark("first");
        require(sent.size() == 2, "each marker must be sent once");
        client.pass("markers_delivered");
        require(!recorder.completed && recorder.pendingScreenshots.isEmpty(),
            "sending a marker must not allow the client to finish before acknowledgement");
        client.receive("mark other");
        client.receive("mark second");
        require(!recorder.completed, "every outgoing marker must be acknowledged");
        client.receive("mark first");
        require(recorder.completed && recorder.resultPassed && recorder.pendingScreenshots.size() == 1,
            "the last acknowledgement must release pending success");
        client.receive("mark first");
        require(recorder.pendingScreenshots.size() == 1, "duplicate acknowledgements must not repeat completion");

        Recorder failed = new Recorder();
        TestClient failing = new TestClient(failed, sent::add);
        failing.mark("pending");
        failing.pass("pending_success");
        require(failing.completing(), "pending acknowledgements must pause fixture work");
        failing.fail("assertion_failed");
        failing.receive("mark pending");
        require(failed.completed && !failed.resultPassed && !failing.completing(),
            "a delayed acknowledgement must not overturn failure");
    }

    private static void checkpoints() throws Exception {
        Path directory = Files.createTempDirectory("e2e-checkpoint-");
        Recorder recorder = new Recorder();
        recorder.artifacts = directory;
        TestClient client = new TestClient(recorder);
        try (var events = Files.newBufferedWriter(directory.resolve("events.jsonl"))) {
            recorder.events = events;
            Recorder.Capture capture = client.screenshot("before_reload");
            require(!capture.done(), "requesting a screenshot must not advance a checkpoint");
            require(capture == client.screenshot("before_reload") && recorder.pendingScreenshots.size() == 1,
                "waiting across fixture ticks must reuse the pending capture");
            recorder.captureFinished(capture, true);
            require(capture.done() && client.screenshot("before_reload").done(),
                "saved screenshots must release their checkpoint");
            recorder.captureFinished(capture, false);
            require(capture.done(), "duplicate callbacks must not change completion");
            require(!recorder.completed && !recorder.resultPublished, "checkpoints must not finish the test");
            Recorder.Capture missing = client.screenshot("after_reload");
            require(missing != capture && !missing.done(), "different checkpoints must capture different states");
            recorder.captureFinished(missing, false);
            require(!missing.done() && recorder.completed && !recorder.resultPassed,
                "a missing checkpoint screenshot must fail the run");
            recorder.captureFinished(recorder.pendingScreenshots.getLast(), true);
            require(Files.readString(directory.resolve("client.result"))
                .equals("FAIL checkpoint_screenshot_missing_after_reload\n"), "checkpoint failure must be published");
        } finally {
            try (var files = Files.list(directory)) {
                for (Path file : files.toList()) Files.delete(file);
            }
            Files.delete(directory);
        }
    }

    private static void lateChatFailure(boolean roster) throws Exception {
        Path directory = Files.createTempDirectory("e2e-late-chat-");
        Recorder recorder = new Recorder();
        recorder.artifacts = directory;
        recorder.enabled = true;
        recorder.expectedPeers = java.util.List.of("alice", "bob");
        recorder.peer = "alice";
        recorder.fixture = roster ? new JoinLeaveFixture(recorder) : new ChatFixture(recorder);
        try (var events = Files.newBufferedWriter(directory.resolve("events.jsonl"))) {
            recorder.events = events;
            String message = roster ? "alice joined the game" : "<alice> e2e-chat:alice:short";
            recorder.chatReceived(message);
            recorder.pass("chat_complete");
            Recorder.Capture success = recorder.pendingScreenshots.getFirst();
            recorder.chatReceived(message);
            require(!recorder.resultPassed && !recorder.functionalPassed,
                "a duplicate before publication must overturn pending success");
            recorder.captureFinished(success, true);
            require(!recorder.resultPublished, "a superseded capture must not publish");
            recorder.captureFinished(recorder.pendingScreenshots.getFirst(), true);
            String reason = roster ? "duplicate_join_or_leave" : "chat_duplicate_or_reordered";
            require(Files.readString(directory.resolve("alice.result")).equals("FAIL " + reason + "\n"),
                "late assertion failure must be published");
        } finally {
            try (var files = Files.list(directory)) {
                for (Path file : files.toList()) Files.delete(file);
            }
            Files.delete(directory);
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
