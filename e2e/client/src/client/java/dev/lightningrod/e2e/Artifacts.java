package dev.lightningrod.e2e;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

final class Artifacts {
    // Readers use the destination's existence as completion, so publish only closed files.
    static void publish(Path destination, String contents) throws IOException {
        Path pending = Files.createTempFile(destination.getParent(), "." + destination.getFileName() + "-", ".tmp");
        try {
            Files.writeString(pending, contents, StandardCharsets.UTF_8);
            Files.move(pending, destination, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally {
            Files.deleteIfExists(pending);
        }
    }
}
