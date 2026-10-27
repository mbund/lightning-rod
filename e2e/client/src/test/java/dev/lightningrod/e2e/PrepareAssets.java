package dev.lightningrod.e2e;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorCompletionService;
import java.util.concurrent.Executors;

public final class PrepareAssets {
    private record Asset(String hash, long size) {}

    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("Expected versions.json and asset output directory");
        Path output = Path.of(args[1]);
        Files.createDirectories(output.resolve("indexes"));
        try (HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(30)).build()) {
            JsonObject manifest = json(get(http, "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json", null));
            var assets = new LinkedHashMap<String, Asset>();
            for (var entry : JsonParser.parseString(Files.readString(Path.of(args[0]))).getAsJsonArray()) {
                String release = entry.getAsJsonObject().get("release").getAsString();
                JsonObject version = null;
                for (var candidate : manifest.getAsJsonArray("versions")) {
                    var value = candidate.getAsJsonObject();
                    if (value.get("id").getAsString().equals(release)) version = value;
                }
                if (version == null) throw new IOException("Missing Minecraft version: " + release);
                var index = json(get(http, version.get("url").getAsString(), version.get("sha1").getAsString())).getAsJsonObject("assetIndex");
                byte[] bytes = get(http, index.get("url").getAsString(), index.get("sha1").getAsString());
                String id = index.get("id").getAsString();
                if (!id.matches("[A-Za-z0-9._-]+")) throw new IOException("Invalid asset index: " + id);
                Files.write(output.resolve("indexes").resolve(id + ".json"), bytes);
                for (var asset : json(bytes).getAsJsonObject("objects").entrySet()) {
                    var value = asset.getValue().getAsJsonObject();
                    String hash = value.get("hash").getAsString();
                    if (!hash.matches("[0-9a-f]{40}")) throw new IOException("Invalid asset hash");
                    assets.put(hash, new Asset(hash, value.get("size").getAsLong()));
                }
            }
            var downloads = new ArrayList<Callable<Void>>();
            for (var asset : assets.values()) downloads.add(() -> {
                String name = asset.hash.substring(0, 2) + "/" + asset.hash;
                Path file = output.resolve("objects").resolve(name);
                boolean existing = Files.exists(file);
                byte[] bytes = existing ? Files.readAllBytes(file) : get(http, "https://resources.download.minecraft.net/" + name, asset.hash);
                if (existing) verify(bytes, asset.hash);
                if (bytes.length != asset.size) throw new IOException("Incorrect asset size: " + asset.hash);
                if (!existing) {
                    Files.createDirectories(file.getParent());
                    Files.write(file, bytes);
                }
                return null;
            });
            try (var workers = Executors.newFixedThreadPool(8)) {
                var results = new ExecutorCompletionService<Void>(workers);
                try {
                    for (var download : downloads) results.submit(download);
                    for (int count = 0; count < downloads.size(); count++) {
                        results.take().get();
                        if ((count + 1) % 1000 == 0) System.out.printf("Verified %d/%d assets%n", count + 1, downloads.size());
                    }
                } finally {
                    workers.shutdownNow();
                }
            }
            long bytes = assets.values().stream().mapToLong(Asset::size).sum();
            System.out.printf("Prepared %d unique assets, %.2f MiB%n", assets.size(), bytes / 1048576.0);
        }
    }

    private static JsonObject json(byte[] bytes) {
        return JsonParser.parseString(new String(bytes, StandardCharsets.UTF_8)).getAsJsonObject();
    }

    private static byte[] get(HttpClient http, String url, String hash) throws Exception {
        var request = HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(60)).GET().build();
        var response = http.send(request, HttpResponse.BodyHandlers.ofByteArray());
        if (response.statusCode() != 200) throw new IOException("HTTP " + response.statusCode() + ": " + url);
        if (hash != null) verify(response.body(), hash);
        return response.body();
    }

    private static void verify(byte[] bytes, String hash) throws Exception {
        String actual = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-1").digest(bytes));
        if (!actual.equals(hash)) throw new IOException("Asset checksum mismatch: " + hash);
    }
}
