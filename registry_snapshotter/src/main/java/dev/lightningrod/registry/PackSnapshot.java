package dev.lightningrod.registry;

import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.zip.ZipFile;
import java.io.InputStreamReader;
import com.google.gson.JsonParser;
import net.minecraft.SharedConstants;
import net.minecraft.server.packs.resources.Resource;
import net.minecraft.server.packs.resources.ResourceManager;

final class PackSnapshot {
    static void write(Path destination, ResourceManager resources) throws Exception {
        Files.createDirectories(destination.toAbsolutePath().getParent());
        var roots = new TreeSet<String>();
        var source = Path.of(SharedConstants.class.getProtectionDomain().getCodeSource().getLocation().toURI());
        try (var archive = new ZipFile(source.toFile())) {
            for (var entry : archive.stream().filter(entry -> !entry.isDirectory() && entry.getName().startsWith("data/")).toList()) {
                var name = entry.getName();
                int namespace = name.indexOf('/', "data/".length());
                int root = name.indexOf('/', namespace + 1);
                if (namespace >= 0 && root >= 0) roots.add(name.substring(namespace + 1, root));
            }
        }
        // The vanilla resource manager rejects an empty directory prefix.
        var selected = new TreeMap<String, Resource>();
        for (var root : roots) resources.listResources(root, id -> true).forEach((id, resource) -> selected.put(id.toString(), resource));
        var entries = selected.entrySet();
        try (var output = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(destination)))) {
            output.write("LRPACK02".getBytes(StandardCharsets.US_ASCII));
            try (var input = SharedConstants.class.getResourceAsStream("/version.json")) {
                var version = JsonParser.parseReader(new InputStreamReader(input, StandardCharsets.UTF_8)).getAsJsonObject().getAsJsonObject("pack_version");
                output.writeInt(version.has("data") ? version.get("data").getAsInt() : version.get("data_major").getAsInt());
                output.writeInt(version.has("data_minor") ? version.get("data_minor").getAsInt() : 0);
            }
            output.writeInt(entries.size());
            for (var entry : entries) {
                var name = entry.getKey().toString().getBytes(StandardCharsets.UTF_8);
                byte[] bytes;
                try (var input = entry.getValue().open()) { bytes = input.readAllBytes(); }
                if (name.length > 65535) throw new IllegalStateException("Resource name too long");
                output.writeShort(name.length);
                output.write(name);
                output.writeInt(bytes.length);
                output.write(bytes);
            }
        }
    }
}
