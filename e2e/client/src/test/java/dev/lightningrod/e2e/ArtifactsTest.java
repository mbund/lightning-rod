package dev.lightningrod.e2e;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

public final class ArtifactsTest {
    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("e2e-artifacts-");
        Path result = directory.resolve("alice.result");
        String first = "PASS " + "a".repeat(8192) + "\n";
        String second = "FAIL " + "b".repeat(4096) + "\n";
        AtomicBoolean done = new AtomicBoolean();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread reader = new Thread(() -> {
            try {
                while (!done.get()) {
                    if (!Files.exists(result)) continue;
                    String observed = Files.readString(result);
                    if (!observed.equals(first) && !observed.equals(second))
                        throw new AssertionError("reader observed an incomplete result");
                }
            } catch (Throwable error) { failure.set(error); }
        });
        reader.start();
        try {
            for (int i = 0; i < 1000; i++) Artifacts.publish(result, i % 2 == 0 ? first : second);
        } finally {
            done.set(true);
            reader.join();
            try (var files = Files.list(directory)) {
                for (Path file : files.toList()) Files.delete(file);
            }
            Files.delete(directory);
        }
        if (failure.get() != null) throw new AssertionError("atomic publication failed", failure.get());
    }
}
