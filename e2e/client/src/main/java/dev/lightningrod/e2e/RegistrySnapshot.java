package dev.lightningrod.e2e;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Comparator;
import java.util.List;
import java.util.TreeMap;
import java.util.Arrays;
import io.netty.buffer.Unpooled;
import net.minecraft.Bootstrap;
import net.minecraft.SharedConstants;
import net.minecraft.nbt.NbtIo;
import net.minecraft.nbt.NbtOps;
import net.minecraft.registry.RegistryLoader;
import net.minecraft.registry.RegistryOps;
import net.minecraft.registry.DynamicRegistryManager;
import net.minecraft.registry.Registries;
import net.minecraft.registry.ServerDynamicRegistryType;
import net.minecraft.registry.tag.TagGroupLoader;
import net.minecraft.registry.tag.TagPacketSerializer;
import net.minecraft.resource.LifecycledResourceManagerImpl;
import net.minecraft.resource.ResourceType;
import net.minecraft.resource.VanillaDataPackProvider;
import net.minecraft.network.PacketByteBuf;
import net.fabricmc.api.ModInitializer;

/** Offline data extraction, not a replacement client or a server test. */
public final class RegistrySnapshot implements ModInitializer {
    @Override public void onInitialize() {
        String destination = System.getProperty("mcc.snapshotOutput");
        if (destination == null) return;
        try {
            main(new String[] { destination });
        } catch (Exception error) {
            error.printStackTrace();
            System.exit(1);
        }
        System.exit(0);
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("Expected output path");
        SharedConstants.createGameVersion();
        Bootstrap.initialize();
        Registries.bootstrap();
        var builtin = DynamicRegistryManager.of(Registries.REGISTRIES);
        try (var resources = new LifecycledResourceManagerImpl(ResourceType.SERVER_DATA,
                List.of(VanillaDataPackProvider.createDefaultPack()))) {
            var pending = TagGroupLoader.startReload(resources, builtin);
            for (var tags : pending) tags.apply();
            var dynamic = RegistryLoader.loadFromResource(resources, builtin.stream().toList(), RegistryLoader.DYNAMIC_REGISTRIES);
            var combined = ServerDynamicRegistryType.createCombinedDynamicRegistries().with(ServerDynamicRegistryType.WORLDGEN, dynamic);
            var lookup = combined.getCombinedRegistryManager();
            var destination = Path.of(args[0]);
            Files.createDirectories(destination.toAbsolutePath().getParent());
            var temporary = destination.resolveSibling(destination.getFileName() + ".partial");
            try (var output = new DataOutputStream(Files.newOutputStream(temporary))) {
                output.write("LRREG001".getBytes(StandardCharsets.US_ASCII));
                string(output, SharedConstants.getGameVersion().name());
                output.writeInt(RegistryLoader.SYNCED_REGISTRIES.size());
                for (var registry : RegistryLoader.SYNCED_REGISTRIES) write(output, lookup, registry);
                var tags = new PacketByteBuf(Unpooled.buffer());
                try {
                    var groups = new TreeMap<String, TagPacketSerializer.Serialized>();
                    TagPacketSerializer.serializeTags(combined).forEach((key, value) -> groups.put(key.getValue().toString(), value));
                    tags.writeVarInt(groups.size());
                    var scratch = new PacketByteBuf(Unpooled.buffer());
                    try {
                        for (var group : groups.entrySet()) {
                            tags.writeString(group.getKey());
                            scratch.clear();
                            group.getValue().writeBuf(scratch);
                            var entries = new TreeMap<String, int[]>();
                            int count = scratch.readVarInt();
                            for (int i = 0; i < count; i++) {
                                String name = scratch.readString();
                                int[] values = scratch.readIntArray();
                                Arrays.sort(values);
                                entries.put(name, values);
                            }
                            if (scratch.isReadable()) throw new IllegalStateException("Trailing tag data");
                            tags.writeVarInt(entries.size());
                            entries.forEach((name, values) -> { tags.writeString(name); tags.writeIntArray(values); });
                        }
                    } finally { scratch.release(); }
                    output.writeInt(tags.readableBytes());
                    tags.readBytes(output, tags.readableBytes());
                } finally { tags.release(); }
            }
            Files.move(temporary, destination, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        }
    }

    private static <T> void write(DataOutputStream output, DynamicRegistryManager lookup,
                                 RegistryLoader.Entry<T> registry) throws Exception {
        string(output, registry.key().getValue().toString());
        var values = lookup.getOrThrow(registry.key());
        var entries = values.streamEntries().sorted(Comparator.comparingInt(entry -> values.getRawId(entry.value()))).toList();
        output.writeInt(entries.size());
        var ops = RegistryOps.of(NbtOps.INSTANCE, lookup);
        for (var entry : entries) {
            string(output, entry.registryKey().getValue().toString());
            var nbt = registry.elementCodec().encodeStart(ops, entry.value()).getOrThrow();
            var bytes = new ByteArrayOutputStream();
            NbtIo.writeForPacket(nbt, new DataOutputStream(bytes));
            output.writeInt(bytes.size());
            bytes.writeTo(output);
        }
    }

    private static void string(DataOutputStream output, String value) throws Exception {
        var bytes = value.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > 65535) throw new IllegalArgumentException("Identifier too long");
        output.writeShort(bytes.length);
        output.write(bytes);
    }
}
