package dev.lightningrod.e2e;

import java.util.HashSet;
import java.util.Set;
import net.minecraft.client.Minecraft;
import net.minecraft.world.entity.ExperienceOrb;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.Items;

/// Alice draws her bow at the cow the server names, for as long as it says, aiming where the
/// arrow will fall, and lets go. Once the cow is dying she watches its body until it is gone,
/// counting the orbs and items that came out of it, and tells the server.
final class KillFixture extends Fixture {
    private enum Phase { WAITING, SHOOT, SHOT, VERIFIED }
    private Phase phase = Phase.WAITING;
    private int readyJoin = -1;
    private int target;
    private int draw;
    private int drawn;
    /// Ticks the target has stood still, which a full draw waits for: a cow strolling off
    /// moves out of the arrow's way while it flies.
    private int still;
    private double lastX, lastZ;
    private long dyingTick = -1;
    private int deathTime;
    private boolean reported;
    private final Set<Integer> orbs = new HashSet<>();
    private final Set<Integer> items = new HashSet<>();

    KillFixture(Recorder r) { super(r); }

    @Override void message(String text) {
        if (text.startsWith("shoot ")) {
            String[] fields = text.split(" ");
            draw = Integer.parseInt(fields[1]);
            target = Integer.parseInt(fields[2]);
            drawn = 0;
            still = 0;
            phase = Phase.SHOOT;
        } else if (text.equals("verified")) phase = Phase.VERIFIED;
        else throw new IllegalStateException("Unexpected kill message " + text);
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || game.gameMode == null || r.terrainTick < 0 || missing != 0) return;
        if (readyJoin != r.joins) { readyJoin = r.joins; client.send("ready"); return; }
        if (r.tick - r.terrainTick > 2400) { client.fail("kill_timeout_" + phase); return; }
        if (phase == Phase.VERIFIED) { client.pass("cow_panicked_died_dropped_and_vanished"); return; }
        if (phase == Phase.WAITING) return;
        watch(game);
        if (phase != Phase.SHOOT || !game.player.getMainHandItem().is(Items.BOW)) return;
        if (!(game.level.getEntity(target) instanceof LivingEntity cow)) return;
        aim(game, cow);
        if (Math.abs(cow.getX() - lastX) < 0.001 && Math.abs(cow.getZ() - lastZ) < 0.001) still++; else still = 0;
        lastX = cow.getX();
        lastZ = cow.getZ();
        // A full draw holds at full power until the target has stood still a while.
        boolean holding = ++drawn < draw || (draw >= 20 && still < 5);
        game.options.keyUse.setDown(holding);
        if (!holding) phase = Phase.SHOT;
    }

    /// Once the cow is dying: how long until it is gone, how far its death animation ran, and the
    /// orbs and items near its body.
    private void watch(Minecraft game) {
        if (reported) return;
        var entity = game.level.getEntity(target);
        if (entity instanceof LivingEntity cow && cow.isDeadOrDying()) {
            if (dyingTick < 0) dyingTick = r.tick;
            deathTime = Math.max(deathTime, cow.deathTime);
            for (var near : game.level.getEntities(cow, cow.getBoundingBox().inflate(3))) {
                if (near instanceof ExperienceOrb) orbs.add(near.getId());
                else if (near instanceof ItemEntity) items.add(near.getId());
            }
        } else if (entity == null && dyingTick >= 0) {
            reported = true;
            client.send("gone " + (r.tick - dyingTick) + " " + deathTime + " " + orbs.size() + " " + items.size());
        }
    }

    /// Faces the cow and picks the pitch whose arrow, at the speed this draw gives, falls through
    /// the middle of it: BowItem.getPowerForTime, then an arrow's drag and gravity a tick at a time.
    private void aim(Minecraft game, LivingEntity cow) {
        var eye = game.player.getEyePosition();
        double dx = cow.getX() - eye.x;
        double dz = cow.getZ() - eye.z;
        double horizontal = Math.sqrt(dx * dx + dz * dz);
        double rise = cow.getY() + cow.getBbHeight() / 2 - (eye.y - 0.1);
        float held = (draw - 1) / 20.0F;
        double speed = Math.min(1.0F, (held * held + held * 2.0F) / 3.0F) * 3.0;
        float best = 0;
        double error = Double.MAX_VALUE;
        for (float pitch = -30; pitch <= 30; pitch += 0.05F) {
            double radians = Math.toRadians(pitch);
            double along = 0, y = 0, vh = Math.cos(radians) * speed, vy = -Math.sin(radians) * speed;
            for (int step = 0; step < 100 && along < horizontal; step++) {
                double nextAlong = along + vh, nextY = y + vy;
                if (nextAlong >= horizontal) y += (nextY - y) * (horizontal - along) / vh;
                else y = nextY;
                along = nextAlong;
                vh *= 0.99;
                vy = vy * 0.99 - 0.05;
            }
            if (Math.abs(y - rise) < error) { error = Math.abs(y - rise); best = pitch; }
        }
        game.player.setYRot((float) Math.toDegrees(Math.atan2(-dx, dz)));
        game.player.setXRot(best);
    }
}
