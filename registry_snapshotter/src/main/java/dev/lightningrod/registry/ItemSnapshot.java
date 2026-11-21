package dev.lightningrod.registry;

import java.io.DataOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;

/**
 * Item facts entity physics reads: the damage type tag each item resists by default, as its
 * damage_resistant component names it, which decides what a dropped item survives.
 */
final class ItemSnapshot {
    static void write(DataOutputStream output) throws Exception {
        List<String> tags = new ArrayList<>();
        int[] resisted = new int[BuiltInRegistries.ITEM.size()];
        int at = 0;
        for (var item : BuiltInRegistries.ITEM) {
            var resistant = item.components().get(DataComponents.DAMAGE_RESISTANT);
            if (resistant != null) {
                String name = PhysicsApi.resistedTag(resistant);
                int index = tags.indexOf(name);
                if (index < 0) {
                    tags.add(name);
                    index = tags.size() - 1;
                }
                if (index > 254) throw new IllegalStateException("Too many resisted damage tags");
                resisted[at] = index + 1;
            }
            at++;
        }
        output.writeInt(tags.size());
        for (var tag : tags) {
            byte[] bytes = tag.getBytes(StandardCharsets.UTF_8);
            output.writeShort(bytes.length);
            output.write(bytes);
        }
        output.writeInt(resisted.length);
        for (int index : resisted) output.writeByte(index);
        writeAttributes(output);
    }

    /**
     * Each item's default attribute modifiers, as its attribute_modifiers component lists them, its
     * weapon component, and its blocks_attacks component. Names go in one table: attributes,
     * modifier ids, slot groups, damage type tags and sounds.
     */
    private static void writeAttributes(DataOutputStream output) throws Exception {
        List<String> names = new ArrayList<>();
        var items = new ArrayList<net.minecraft.world.item.Item>();
        for (var item : BuiltInRegistries.ITEM) items.add(item);
        for (var item : items) {
            var modifiers = item.components().get(DataComponents.ATTRIBUTE_MODIFIERS);
            if (modifiers == null) continue;
            for (var entry : modifiers.modifiers()) {
                name(names, entry.attribute().getRegisteredName());
                name(names, entry.modifier().id().toString());
                name(names, entry.slot().getSerializedName());
            }
            var blocks = item.components().get(DataComponents.BLOCKS_ATTACKS);
            if (blocks == null) continue;
            name(names, PhysicsApi.bypassedTag(blocks));
            name(names, blocks.blockSound().map(sound -> sound.value().location().toString()).orElse(""));
            name(names, blocks.disableSound().map(sound -> sound.value().location().toString()).orElse(""));
        }
        output.writeInt(names.size());
        for (var value : names) {
            byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
            output.writeShort(bytes.length);
            output.write(bytes);
        }
        output.writeInt(items.size());
        for (var item : items) {
            var modifiers = item.components().get(DataComponents.ATTRIBUTE_MODIFIERS);
            var entries = modifiers == null ? List.<net.minecraft.world.item.component.ItemAttributeModifiers.Entry>of() : modifiers.modifiers();
            if (entries.size() > 255) throw new IllegalStateException("Too many attribute modifiers on an item");
            output.writeByte(entries.size());
            for (var entry : entries) {
                output.writeShort(names.indexOf(entry.attribute().getRegisteredName()));
                output.writeShort(names.indexOf(entry.modifier().id().toString()));
                output.writeShort(names.indexOf(entry.slot().getSerializedName()));
                output.writeByte(entry.modifier().operation().id());
                output.writeDouble(entry.modifier().amount());
            }
            var weapon = item.components().get(DataComponents.WEAPON);
            output.writeByte(weapon == null ? 0 : 1);
            if (weapon != null) {
                if (weapon.itemDamagePerAttack() < 0 || weapon.itemDamagePerAttack() > 65535) throw new IllegalStateException("Weapon wear out of range");
                output.writeShort(weapon.itemDamagePerAttack());
                output.writeFloat(weapon.disableBlockingForSeconds());
            }
            writeBlocking(output, names, item.components().get(DataComponents.BLOCKS_ATTACKS));
        }
    }

    /**
     * A blocks_attacks component: how long a raised item takes to block, what it takes off each
     * hit by angle, how it wears, and what passes it. A reduction limited to some damage types is
     * marked so, since no vanilla item limits one.
     */
    private static void writeBlocking(DataOutputStream output, List<String> names, net.minecraft.world.item.component.BlocksAttacks blocks) throws Exception {
        output.writeByte(blocks == null ? 0 : 1);
        if (blocks == null) return;
        output.writeFloat(blocks.blockDelaySeconds());
        output.writeFloat(blocks.disableCooldownScale());
        var reductions = blocks.damageReductions();
        if (reductions.size() > 255) throw new IllegalStateException("Too many damage reductions");
        output.writeByte(reductions.size());
        for (var reduction : reductions) {
            output.writeFloat(reduction.horizontalBlockingAngle());
            output.writeByte(reduction.type().isPresent() ? 1 : 0);
            output.writeFloat(reduction.base());
            output.writeFloat(reduction.factor());
        }
        output.writeFloat(blocks.itemDamage().threshold());
        output.writeFloat(blocks.itemDamage().base());
        output.writeFloat(blocks.itemDamage().factor());
        output.writeShort(names.indexOf(PhysicsApi.bypassedTag(blocks)));
        output.writeShort(names.indexOf(blocks.blockSound().map(sound -> sound.value().location().toString()).orElse("")));
        output.writeShort(names.indexOf(blocks.disableSound().map(sound -> sound.value().location().toString()).orElse("")));
    }

    private static void name(List<String> names, String value) {
        if (!names.contains(value)) names.add(value);
        if (names.size() > 65535) throw new IllegalStateException("Too many attribute names");
    }
}
