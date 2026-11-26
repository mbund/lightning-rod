package dev.lightningrod.e2e;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import net.minecraft.client.Minecraft;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.phys.Vec3;

/// The client's half of the entity proof: each entity's exact state at the end of every tick,
/// and after every entity packet, for the runner to hold to the server's trace. Living entities
/// interpolate and are left out. A packet is stamped with the ticks done when it was handled, so
/// the next tick is the first it shows in. Doubles go as their raw bits in hex.
public final class EntityTrace {
    static final EntityTrace INSTANCE = new EntityTrace();
    private BufferedWriter out;
    private long ticks;

    public static EntityTrace instance() { return INSTANCE; }

    void open(Path artifacts, String peer) {
        try {
            out = Files.newBufferedWriter(artifacts.resolve(peer + ".entities"));
        } catch (IOException error) { throw new IllegalStateException("cannot open the entity trace", error); }
    }

    /// The end of a client tick: every traced entity as the tick left it.
    void tick(Minecraft client) {
        if (out == null || client.level == null) return;
        ticks++;
        for (Entity entity : client.level.entitiesForRendering()) {
            if (entity instanceof LivingEntity) continue;
            line("t " + ticks + " " + entity.getId(), entity);
        }
        // A client may be stopped without closing: what each tick wrote is kept.
        try {
            out.flush();
        } catch (IOException error) { throw new IllegalStateException("cannot write the entity trace", error); }
    }

    /// An entity packet, handled: the entity as it left it.
    public void packet(String kind, int id) {
        if (out == null) return;
        Minecraft client = Minecraft.getInstance();
        if (client.level == null) return;
        Entity entity = client.level.getEntity(id);
        if (entity == null || entity instanceof LivingEntity) return;
        line("p " + ticks + " " + kind + " " + id, entity);
    }

    public void removed(int id) {
        if (out == null) return;
        write("r " + ticks + " " + id + "\n");
    }

    void close() {
        if (out == null) return;
        try {
            out.close();
        } catch (IOException error) { throw new IllegalStateException("cannot write the entity trace", error); }
        out = null;
    }

    private void line(String prefix, Entity entity) {
        Vec3 motion = entity.getDeltaMovement();
        write(prefix + " " + bits(entity.getX()) + " " + bits(entity.getY()) + " " + bits(entity.getZ()) + " " + bits(motion.x) + " " + bits(motion.y) + " " + bits(motion.z) + " " + (entity.onGround() ? 1 : 0) + "\n");
    }

    private static String bits(double value) { return Long.toHexString(Double.doubleToRawLongBits(value)); }

    private void write(String text) {
        try {
            out.write(text);
        } catch (IOException error) { throw new IllegalStateException("cannot write the entity trace", error); }
    }
}
