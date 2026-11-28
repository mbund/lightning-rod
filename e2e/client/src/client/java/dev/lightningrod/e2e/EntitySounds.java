package dev.lightningrod.e2e;

import java.util.HashSet;
import java.util.Set;

/// The sounds the client was told to play following an entity, ClientboundSoundEntityPacket, by
/// sound and entity: kept whether or not the client can play sound, as a headless one cannot.
public final class EntitySounds {
    private static final Set<String> heard = new HashSet<>();

    private EntitySounds() {}

    public static synchronized void heard(String sound, int entity) {
        heard.add(sound + "@" + entity);
    }

    /// Whether a sound whose event names `sound` came following entity `entity`.
    public static synchronized boolean followed(String sound, int entity) {
        for (String each : heard) if (each.endsWith("@" + entity) && each.contains(sound)) return true;
        return false;
    }
}
