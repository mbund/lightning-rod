package dev.lightningrod.registry;

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
import net.minecraft.SharedConstants;
import net.minecraft.core.Registry;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.nbt.NbtIo;
import net.minecraft.nbt.NbtOps;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.resources.RegistryDataLoader;
import net.minecraft.resources.RegistryOps;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.RegistryLayer;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.tags.TagLoader;
import net.minecraft.tags.TagNetworkSerialization;
import net.fabricmc.api.ModInitializer;

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
        SharedConstants.tryDetectVersion();
        Bootstrap.bootStrap();
        var builtin = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
        try (var resources = new MultiPackResourceManager(PackType.SERVER_DATA,
                List.of(ServerPacksSource.createVanillaPackSource()))) {
            var pending = TagLoader.loadTagsForExistingRegistries(resources, builtin);
            for (var tags : pending) tags.apply();
            var dynamic = RegistryLoader.load(resources, builtin);
            var combined = RegistryLayer.createRegistryAccess().replaceFrom(RegistryLayer.WORLDGEN, dynamic);
            var lookup = combined.compositeAccess();
            var destination = Path.of(args[0]);
            Files.createDirectories(destination.toAbsolutePath().getParent());
            var temporary = destination.resolveSibling(destination.getFileName() + ".partial");
            try (var output = new DataOutputStream(Files.newOutputStream(temporary))) {
                output.write("LRREG002".getBytes(StandardCharsets.US_ASCII));
                string(output, System.getProperty("mcc.minecraftVersion"));
                output.writeInt(RegistryDataLoader.SYNCHRONIZED_REGISTRIES.size() + 5);
                for (var registry : RegistryDataLoader.SYNCHRONIZED_REGISTRIES) write(output, lookup, registry);
                writeStatic(output, BuiltInRegistries.POTION);
                writeStatic(output, BuiltInRegistries.DATA_COMPONENT_PREDICATE_TYPE);
                writeStatic(output, BuiltInRegistries.VILLAGER_TYPE);
                writeStatic(output, BuiltInRegistries.ENTITY_TYPE);
                writeStatic(output, BuiltInRegistries.BLOCK_ENTITY_TYPE);
                var tags = new FriendlyByteBuf(Unpooled.buffer());
                try {
                    var groups = new TreeMap<String, TagNetworkSerialization.NetworkPayload>();
                    TagNetworkSerialization.serializeTagsToNetwork(combined).forEach((key, value) -> groups.put(RegistryApi.name(key), value));
                    tags.writeVarInt(groups.size());
                    var scratch = new FriendlyByteBuf(Unpooled.buffer());
                    try {
                        for (var group : groups.entrySet()) {
                            tags.writeUtf(group.getKey());
                            scratch.clear();
                            group.getValue().write(scratch);
                            var entries = new TreeMap<String, int[]>();
                            int count = scratch.readVarInt();
                            for (int i = 0; i < count; i++) {
                                String name = scratch.readUtf();
                                int[] values = scratch.readVarIntArray();
                                Arrays.sort(values);
                                entries.put(name, values);
                            }
                            if (scratch.isReadable()) throw new IllegalStateException("Trailing tag data");
                            tags.writeVarInt(entries.size());
                            entries.forEach((name, values) -> { tags.writeUtf(name); tags.writeVarIntArray(values); });
                        }
                    } finally { scratch.release(); }
                    output.writeInt(tags.readableBytes());
                    tags.readBytes(output, tags.readableBytes());
                } finally { tags.release(); }
            }
            Files.move(temporary, destination, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        }
    }

    private static <T> void write(DataOutputStream output, RegistryAccess lookup,
                                 RegistryDataLoader.RegistryData<T> registry) throws Exception {
        string(output, RegistryApi.name(registry.key()));
        output.writeBoolean(true);
        var values = lookup.lookupOrThrow(registry.key());
        var entries = values.listElements().sorted(Comparator.comparingInt(entry -> values.getId(entry.value()))).toList();
        output.writeInt(entries.size());
        var ops = RegistryOps.create(NbtOps.INSTANCE, lookup);
        for (var entry : entries) {
            string(output, RegistryApi.name(entry.key()));
            var nbt = registry.elementCodec().encodeStart(ops, entry.value()).getOrThrow();
            var bytes = new ByteArrayOutputStream();
            NbtIo.writeAnyTag(nbt, new DataOutputStream(bytes));
            output.writeInt(bytes.size());
            bytes.writeTo(output);
        }
    }

    private static <T> void writeStatic(DataOutputStream output, Registry<T> registry) throws Exception {
        string(output, RegistryApi.name(registry.key()));
        output.writeBoolean(false);
        output.writeInt(registry.size());
        for (int id = 0; id < registry.size(); id++) {
            string(output, registry.getKey(registry.byId(id)).toString());
            output.writeInt(0);
        }
    }

    private static void string(DataOutputStream output, String value) throws Exception {
        var bytes = value.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > 65535) throw new IllegalArgumentException("Identifier too long");
        output.writeShort(bytes.length);
        output.write(bytes);
    }
}
