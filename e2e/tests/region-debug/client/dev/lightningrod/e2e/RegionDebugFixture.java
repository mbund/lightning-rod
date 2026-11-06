package dev.lightningrod.e2e;

import net.minecraft.client.Minecraft;
import net.minecraft.network.protocol.game.ClientboundAddEntityPacket;
import net.minecraft.world.entity.Display;
import net.minecraft.core.registries.BuiltInRegistries;

final class RegionDebugFixture extends Fixture {
    private enum Phase { START, BOUNDS, VISIBLE, FREEZE, MOVED, LIVE, OFF, DONE }
    private Phase phase = Phase.START;
    private String overlay = "";
    private String frozen = "";
    private int displays;
    private long stoppedTick;
    private double initialX;
    private long started;
    private boolean complete;
    private boolean notified;

    RegionDebugFixture(Recorder r) { super(r); }
    @Override boolean encrypted() { return true; }
    @Override boolean prepare(Minecraft game) {
        game.getTutorial().setStep(net.minecraft.client.tutorial.TutorialSteps.NONE);
        return true;
    }
    @Override void message(String text) {
        if (!text.equals("complete")) throw new IllegalArgumentException(text);
        complete = true;
    }
    @Override void overlay(String text) { overlay = text; }
    @Override void entitySpawned(ClientboundAddEntityPacket packet) {
        if (!BuiltInRegistries.ENTITY_TYPE.getKey(packet.getType()).toString().equals("minecraft:block_display")) return;
        if (!r.peer.equals("alice")) { client.fail("private_overlay_leaked"); return; }
        if (!Double.isFinite(packet.getX()) || !Double.isFinite(packet.getY()) || !Double.isFinite(packet.getZ())) {
            client.fail("nonfinite_overlay_position");
            return;
        }
        displays++;
    }

    @Override void tick(Minecraft game, int loaded, int missing) {
        if (game.player == null || game.level == null || r.terrainTick < 0) return;
        if (started == 0) started = System.nanoTime();
        if (System.nanoTime() - started > 45_000_000_000L) { client.fail("region_debug_timeout_" + phase + "_displays_" + displays + "_overlay_" + overlay); return; }
        int visibleDisplays = 0;
        for (var entity : game.level.entitiesForRendering()) {
            if (entity instanceof Display.BlockDisplay && !entity.isRemoved()) {
                if (!r.peer.equals("alice")) { client.fail("private_overlay_leaked"); return; }
                if (!entity.isCurrentlyGlowing()) { client.fail("overlay_not_glowing"); return; }
                visibleDisplays++;
            }
        }
        var connection = game.getConnection();
        if (!r.peer.equals("alice")) {
            if (connection.getCommands().getRoot().getChild("regions") != null || !overlay.isEmpty()) {
                client.fail("private_debug_access_leaked");
                return;
            }
            if (complete) client.pass("region_overlay_private");
            return;
        }
        switch (phase) {
            case START -> {
                if (loaded < 25 || missing != 0 || connection.getCommands().getRoot().getChild("regions") == null) return;
                initialX = game.player.getX();
                connection.sendCommand("regions");
                phase = Phase.BOUNDS;
            }
            case BOUNDS -> {
                if (visibleDisplays != 12 || !overlay.startsWith("bounds ")) return;
                if (!client.screenshot("source_envelopes").done()) return;
                connection.sendCommand("regions visibility");
                phase = Phase.VISIBLE;
            }
            case VISIBLE -> {
                if (!overlay.startsWith("visibility ")) return;
                if (!client.screenshot("section_disclosure").done()) return;
                connection.sendCommand("regions freeze");
                phase = Phase.FREEZE;
            }
            case FREEZE -> {
                if (!overlay.startsWith("FROZEN ")) return;
                frozen = overlay;
                client.send("move");
                phase = Phase.MOVED;
            }
            case MOVED -> {
                if (game.player.getX() < initialX + 31 || missing != 0) return;
                if (!overlay.equals(frozen)) { client.fail("frozen_snapshot_changed"); return; }
                if (!client.screenshot("frozen_after_movement").done()) return;
                connection.sendCommand("regions live");
                phase = Phase.LIVE;
            }
            case LIVE -> {
                if (overlay.startsWith("FROZEN ") || overlay.equals(frozen.substring(7))) return;
                connection.sendCommand("regions off");
                phase = Phase.OFF;
            }
            case OFF -> {
                if (!r.receivedChat.contains("Region overlay disabled")) return;
                stoppedTick = r.tick;
                phase = Phase.DONE;
            }
            case DONE -> {
                if (visibleDisplays != 0) return;
                if (r.tick - stoppedTick < 15) return;
                if (!notified) { client.send("complete"); notified = true; }
                if (!complete) return;
                client.pass("region_overlay_packets_freeze_resume_and_privacy");
            }
        }
    }
}
