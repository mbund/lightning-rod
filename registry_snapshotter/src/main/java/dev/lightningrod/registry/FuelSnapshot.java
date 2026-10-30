package dev.lightningrod.registry;

import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.tags.TagKey;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.item.Item;
import net.minecraft.world.level.ItemLike;
import net.minecraft.world.level.block.entity.FuelValues;

public final class FuelSnapshot {
    private record Rule(int kind, String name, int ticks) {}
    private static final ArrayList<Rule> rules = new ArrayList<>();
    private static Thread recording;
    private static int depth;

    public static void item(ItemLike item, int ticks) {
        begin(0, BuiltInRegistries.ITEM.getKey(item.asItem()).toString(), ticks);
    }
    public static void tag(TagKey<Item> tag, int ticks) { begin(1, tag.location().toString(), ticks); }
    public static void remove(TagKey<Item> tag) { begin(2, tag.location().toString(), 0); }
    private static void begin(int kind, String name, int ticks) {
        if (recording != Thread.currentThread()) return;
        if (depth++ == 0) rules.add(new Rule(kind, name, ticks));
    }
    public static void end() {
        if (recording != Thread.currentThread()) return;
        if (depth <= 0) throw new IllegalStateException("Unbalanced fuel recording");
        depth--;
    }

    static void write(Path path, RegistryAccess lookup) throws Exception {
        Files.createDirectories(path.toAbsolutePath().getParent());
        FuelApi.prepare(lookup);
        rules.clear();
        depth = 0;
        recording = Thread.currentThread();
        try { FuelValues.vanillaBurnTimes(lookup, FeatureFlags.DEFAULT_FLAGS); }
        finally { recording = null; }
        if (rules.isEmpty() || depth != 0) throw new IllegalStateException("Fuel builder instrumentation missing");
        try (var output = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(path)))) {
            output.write("LRFUEL02".getBytes(StandardCharsets.US_ASCII));
            output.writeInt(BuiltInRegistries.ITEM.size());
            for (var item : BuiltInRegistries.ITEM) {
                var remainder = FuelApi.remainder(item);
                output.writeInt(remainder.isEmpty() ? -1 : BuiltInRegistries.ITEM.getId(remainder.getItem()));
            }
            output.writeInt(rules.size());
            for (var rule : rules) {
                byte[] name = rule.name().getBytes(StandardCharsets.UTF_8);
                output.writeByte(rule.kind());
                output.writeInt(rule.ticks());
                output.writeShort(name.length);
                output.write(name);
            }
        }
        rules.clear();
    }
}
