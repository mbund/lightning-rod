const lightning_rod = @import("lightning_rod");
const world_clock = lightning_rod.clock;
const Packets = lightning_rod.Packets;
const std = @import("std");

pub const KeepAlive = struct {
    pub const id = "minecraft:keep_alive";

    clock: *world_clock.Clock,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, clock: *world_clock.Clock, outputs: *Packets) !*KeepAlive {
        const self = try allocator.create(KeepAlive);
        self.* = .{ .clock = clock, .outputs = outputs };
        return self;
    }

    pub fn tick(self: *KeepAlive, _: std.mem.Allocator) void {
        const clock = self.clock;
        const outputs = self.outputs;
        for (outputs.activePlaySlots()) |slot| {
            synchronizeLatency(outputs, slot);
            if (!outputs.keepAliveDue(slot, clock.tick)) {
                @branchHint(.likely);
                continue;
            }
            outputs.sendKeepAlive(slot);
        }
    }
};

fn synchronizeLatency(outputs: *Packets, subject: u16) void {
    if (!outputs.latencyDirty(subject) or !outputs.bootstrapComplete(subject)) return;
    for (outputs.activePlaySlots()) |target| {
        if (!outputs.bootstrapComplete(target)) continue;
        if (!outputs.sendLatency(target, subject)) return;
    }
    outputs.finishLatency(subject);
}
