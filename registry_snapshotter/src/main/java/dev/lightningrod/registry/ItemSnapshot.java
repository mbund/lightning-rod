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
    }
}
