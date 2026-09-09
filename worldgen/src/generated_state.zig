const aquifer = @import("aquifer.zig");
const surface = @import("surface.zig");
const feature_data = @import("feature_data");
const minecraft = @import("minecraft_registry");

pub const Kind = enum { base, surface, feature };

pub const GeneratedState = enum(u16) {
    stone = 0,
    air = 1,
    water = 2,
    lava = 3,
    _,

    const surface_offset = 4;
    const feature_offset = surface_offset + surface.stateCount();
    const state_count = feature_offset + feature_data.state_names.len;
    const base_state_ids = [_]u32{
        minecraft.State.parse("minecraft:stone").?.id,
        minecraft.State.parse("minecraft:air").?.id,
        minecraft.State.parse("minecraft:water[level=0]").?.id,
        minecraft.State.parse("minecraft:lava[level=0]").?.id,
    };

    pub fn fromBase(material: aquifer.Material) GeneratedState {
        return switch (material) {
            .stone => .stone,
            .air => .air,
            .water => .water,
            .lava => .lava,
        };
    }

    pub fn fromSurface(index: u16) GeneratedState {
        std.debug.assert(index < surface.stateCount());
        return @enumFromInt(surface_offset + index);
    }

    pub fn fromFeature(index: u16) GeneratedState {
        std.debug.assert(index < feature_data.state_names.len);
        return @enumFromInt(feature_offset + index);
    }

    pub fn surfaceNamed(comptime canonical: []const u8) GeneratedState {
        return fromSurface(surface.stateIndex(canonical));
    }

    pub fn featureNamed(comptime canonical: []const u8) GeneratedState {
        return fromFeature(feature_data.stateIndex(canonical));
    }

    pub fn kind(self: GeneratedState) Kind {
        const value = @intFromEnum(self);
        if (value < surface_offset) return .base;
        if (value < feature_offset) return .surface;
        return .feature;
    }

    pub fn baseMaterial(self: GeneratedState) ?aquifer.Material {
        return switch (self) {
            .stone => .stone,
            .air => .air,
            .water => .water,
            .lava => .lava,
            _ => null,
        };
    }

    pub fn surfaceIndex(self: GeneratedState) ?u16 {
        const value = @intFromEnum(self);
        if (value < surface_offset or value >= feature_offset) return null;
        return @intCast(value - surface_offset);
    }

    pub fn featureIndex(self: GeneratedState) ?u16 {
        @setRuntimeSafety(false);
        const value = @intFromEnum(self);
        if (value < feature_offset) return null;
        return @intCast(value - feature_offset);
    }

    pub fn canonicalName(self: GeneratedState) []const u8 {
        return switch (self.kind()) {
            .base => switch (self.baseMaterial().?) {
                .stone => "minecraft:stone",
                .air => "minecraft:air",
                .water => "minecraft:water[level=0]",
                .lava => "minecraft:lava[level=0]",
            },
            .surface => surface.stateName(self.surfaceIndex().?),
            .feature => feature_data.state_names[self.featureIndex().?],
        };
    }

    pub inline fn block(self: GeneratedState) minecraft.Block {
        return self.canonicalState().block();
    }

    pub inline fn canonicalState(self: GeneratedState) minecraft.State {
        @setRuntimeSafety(false);
        const value = @intFromEnum(self);
        if (value < surface_offset) return .{ .id = base_state_ids[value] };
        if (value < feature_offset)
            return .{ .id = surface.canonicalStateId(@intCast(value - surface_offset)) };
        return .{ .id = feature_data.canonical_state_ids[value - feature_offset] };
    }

    pub inline fn nameEquals(self: GeneratedState, comptime name: []const u8) bool {
        @setEvalBranchQuota(100_000);
        const state = comptime minecraft.State.parse(name) orelse return false;
        return self.canonicalState().id == state.id;
    }

    pub inline fn isLogOrLeaves(self: GeneratedState) bool {
        return switch (self.kind()) {
            .base => false,
            .surface => surface.isLogOrLeaves(self.surfaceIndex().?),
            .feature => feature_data.log_or_leaves[self.featureIndex().?],
        };
    }

    pub inline fn sameCanonicalName(self: GeneratedState, other: GeneratedState) bool {
        return self.canonicalState().id == other.canonicalState().id;
    }
};

const std = @import("std");

comptime {
    std.debug.assert(@sizeOf(GeneratedState) == @sizeOf(u16));
    std.debug.assert(
        4 + surface.stateCount() + feature_data.state_names.len <=
            std.math.maxInt(u16),
    );
}

pub fn featureStateCount() usize {
    return feature_data.state_names.len;
}

pub fn stateCount() usize {
    return GeneratedState.state_count;
}
