const std = @import("std");
const lightning_rod = @import("lightning_rod");

const maximum_region_name_bytes = 64;

pub const Rule = enum(u2) {
    inherit,
    allow,
    deny,
};

pub const Flags = struct {
    break_blocks: Rule = .inherit,
    place_blocks: Rule = .inherit,
    interact_blocks: Rule = .inherit,

    pub const protect = Flags{
        .break_blocks = .deny,
        .place_blocks = .deny,
        .interact_blocks = .deny,
    };
};

pub const Bounds = struct {
    minimum: lightning_rod.geometry.BlockPos,
    maximum: lightning_rod.geometry.BlockPos,

    pub fn contains(self: Bounds, pos: lightning_rod.geometry.BlockPos) bool {
        return pos.x >= self.minimum.x and pos.x <= self.maximum.x and
            pos.y >= self.minimum.y and pos.y <= self.maximum.y and
            pos.z >= self.minimum.z and pos.z <= self.maximum.z;
    }

    fn valid(self: Bounds) bool {
        return self.minimum.x <= self.maximum.x and
            self.minimum.y <= self.maximum.y and
            self.minimum.z <= self.maximum.z;
    }
};

pub const Shape = union(enum) {
    world,
    cuboid: Bounds,
};

pub const Region = struct {
    name: []const u8,
    world: lightning_rod.world_identity.Handle,
    shape: Shape = .world,
    priority: i32 = 0,
    flags: Flags,
};

pub const Config = struct {
    maximum_regions: u16 = 1_024,
};

const Action = enum {
    break_blocks,
    place_blocks,
    interact_blocks,
};

const StoredRegion = struct {
    name: [maximum_region_name_bytes]u8 = undefined,
    name_len: u8 = 0,
    world: lightning_rod.world_identity.Handle,
    shape: Shape,
    priority: i32,
    flags: Flags,

    fn nameSlice(self: *const StoredRegion) []const u8 {
        return self.name[0..self.name_len];
    }

    fn contains(self: *const StoredRegion, world: lightning_rod.world_identity.Handle, pos: lightning_rod.geometry.BlockPos) bool {
        if (!self.world.eql(world)) return false;
        return switch (self.shape) {
            .world => true,
            .cuboid => |bounds| bounds.contains(pos),
        };
    }

    fn rule(self: *const StoredRegion, action: Action) Rule {
        return switch (action) {
            .break_blocks => self.flags.break_blocks,
            .place_blocks => self.flags.place_blocks,
            .interact_blocks => self.flags.interact_blocks,
        };
    }
};

pub const WorldGuard = struct {
    pub const id = "worldguard:regions";

    regions: []StoredRegion,
    region_count: usize = 0,
    players: *lightning_rod.players.Players,
    inputs: *lightning_rod.inputs.Inputs,
    outputs: *lightning_rod.Packets,

    pub fn create(
        allocator: std.mem.Allocator,
        players: *lightning_rod.players.Players,
        inputs: *lightning_rod.inputs.Inputs,
        outputs: *lightning_rod.Packets,
        config: Config,
    ) !*WorldGuard {
        if (config.maximum_regions == 0) return error.InvalidRegionCapacity;
        const self = try allocator.create(WorldGuard);
        self.* = .{
            .regions = try allocator.alloc(StoredRegion, config.maximum_regions),
            .players = players,
            .inputs = inputs,
            .outputs = outputs,
        };
        return self;
    }

    pub fn add(self: *WorldGuard, region: Region) !void {
        if (region.name.len == 0 or region.name.len > maximum_region_name_bytes)
            return error.InvalidRegionName;
        if (region.shape == .cuboid and !region.shape.cuboid.valid())
            return error.InvalidRegionBounds;
        if (self.find(region.name) != null) return error.DuplicateRegion;
        if (self.region_count == self.regions.len) return error.RegionCapacity;
        const stored = &self.regions[self.region_count];
        stored.* = .{
            .world = region.world,
            .shape = region.shape,
            .priority = region.priority,
            .flags = region.flags,
        };
        @memcpy(stored.name[0..region.name.len], region.name);
        stored.name_len = @intCast(region.name.len);
        self.region_count += 1;
    }

    pub fn protectWorld(self: *WorldGuard, name: []const u8, world: lightning_rod.world_identity.Handle) !void {
        try self.add(.{ .name = name, .world = world, .flags = .protect });
    }

    pub fn remove(self: *WorldGuard, name: []const u8) bool {
        const index = self.find(name) orelse return false;
        self.region_count -= 1;
        self.regions[index] = self.regions[self.region_count];
        return true;
    }

    pub fn allowsBreaking(self: *const WorldGuard, world: lightning_rod.world_identity.Handle, pos: lightning_rod.geometry.BlockPos) bool {
        return self.allows(.break_blocks, world, pos);
    }

    pub fn allowsPlacement(self: *const WorldGuard, world: lightning_rod.world_identity.Handle, pos: lightning_rod.geometry.BlockPos) bool {
        return self.allows(.place_blocks, world, pos);
    }

    pub fn allowsInteraction(self: *const WorldGuard, world: lightning_rod.world_identity.Handle, pos: lightning_rod.geometry.BlockPos) bool {
        return self.allows(.interact_blocks, world, pos);
    }

    pub fn tick(self: *WorldGuard, _: std.mem.Allocator) void {
        for (self.players.activeSlots()) |slot| {
            const intent = self.inputs.blockDigIntent(slot) orelse continue;
            const player = &self.players.records[slot];
            if (self.allowsBreaking(player.world, intent.pos)) continue;
            self.inputs.rejectBlockDig(slot);
            self.outputs.block_correction(.{ .slot = slot, .pos = intent.pos });
        }
        for (self.inputs.block_requests[0..self.inputs.block_request_count]) |*request| {
            if (request.handled) continue;
            const allowed = switch (request.kind) {
                .break_block => self.allowsBreaking(request.world, request.pos),
                .use_item_on => if (request.block_state == lightning_rod.registry_data.block_air_default_state)
                    self.allowsInteraction(request.world, request.against_pos)
                else
                    self.allowsPlacement(request.world, request.pos),
            };
            if (allowed) continue;
            request.handled = true;
            self.outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
            if (request.kind == .use_item_on) {
                self.outputs.block_correction(.{ .slot = request.slot, .pos = request.against_pos });
                const player = &self.players.records[request.slot];
                self.outputs.hotbar_changed(.{ .slot = request.slot, .hotbar_slot = player.selected_hotbar_slot });
            }
        }
    }

    fn allows(self: *const WorldGuard, action: Action, world: lightning_rod.world_identity.Handle, pos: lightning_rod.geometry.BlockPos) bool {
        var priority: i32 = std.math.minInt(i32);
        var decision: Rule = .inherit;
        for (self.regions[0..self.region_count]) |*region| {
            if (!region.contains(world, pos)) continue;
            const rule = region.rule(action);
            if (rule == .inherit or region.priority < priority) continue;
            if (region.priority > priority) {
                priority = region.priority;
                decision = rule;
                continue;
            }
            if (rule == .deny) decision = .deny;
        }
        return decision != .deny;
    }

    fn find(self: *const WorldGuard, name: []const u8) ?usize {
        for (self.regions[0..self.region_count], 0..) |*region, index|
            if (std.mem.eql(u8, region.nameSlice(), name)) return index;
        return null;
    }
};

test "higher-priority regions override lower-priority protection" {
    const world = lightning_rod.world_identity.Handle{ .index = 1, .generation = 1 };
    var regions: [2]StoredRegion = undefined;
    var guard = WorldGuard{
        .regions = &regions,
        .players = undefined,
        .inputs = undefined,
        .outputs = undefined,
    };
    try guard.add(.{ .name = "spawn", .world = world, .flags = .protect });
    try guard.add(.{
        .name = "builder",
        .world = world,
        .shape = .{ .cuboid = .{
            .minimum = .{ .x = -1, .y = 0, .z = -1 },
            .maximum = .{ .x = 1, .y = 2, .z = 1 },
        } },
        .priority = 1,
        .flags = .{ .break_blocks = .allow, .place_blocks = .allow },
    });
    try std.testing.expect(guard.allowsBreaking(world, .{ .x = 0, .y = 1, .z = 0 }));
    try std.testing.expect(!guard.allowsBreaking(world, .{ .x = 10, .y = 1, .z = 0 }));
    try std.testing.expect(!guard.allowsInteraction(world, .{ .x = 0, .y = 1, .z = 0 }));
}

test "regions are isolated by world handle" {
    const protected = lightning_rod.world_identity.Handle{ .index = 1, .generation = 1 };
    const other = lightning_rod.world_identity.Handle{ .index = 2, .generation = 1 };
    var regions: [1]StoredRegion = undefined;
    var guard = WorldGuard{
        .regions = &regions,
        .players = undefined,
        .inputs = undefined,
        .outputs = undefined,
    };
    try guard.protectWorld("lobby", protected);
    try std.testing.expect(!guard.allowsPlacement(protected, .{ .x = 0, .y = 0, .z = 0 }));
    try std.testing.expect(guard.allowsPlacement(other, .{ .x = 0, .y = 0, .z = 0 }));
}
