const std = @import("std");
const config = @import("../config.zig").value;
const dimension_api = @import("dimension_api.zig");
const identity = @import("identity.zig");
const preallocated = @import("preallocated");

pub const Border = struct {
    center_x: f64 = 0,
    center_z: f64 = 0,
    diameter: f64 = 59_999_968,
};

pub const Description = struct {
    key: identity.Key,
    name: []const u8,
    dimension: identity.DimensionId,
    generator: identity.GeneratorId,
    seed: u64,
    spawn_x: i32,
    spawn_y: i16,
    spawn_z: i32,
    border: Border = .{},
};

pub const World = struct {
    key: identity.Key,
    name: [config.max_world_name_bytes]u8,
    name_len: u8,
    dimension: identity.DimensionId,
    generator: identity.GeneratorId,
    seed: u64,
    spawn_x: i32,
    spawn_y: i16,
    spawn_z: i32,
    border: Border,
    tickets: u32 = 0,

    pub fn nameSlice(self: *const World) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Context = struct {
    handle: identity.Handle,
    world: *World,
};

pub const Configuration = struct {
    initial: []const Description,
};

pub const Worlds = struct {
    pub const id = "lightning_rod:worlds";

    configuration: Configuration,
    records: []World = &.{},
    generations: []u16 = &.{},
    occupied: []bool = &.{},
    active_handles: []identity.Handle = &.{},
    active_positions: []u16 = &.{},
    free_indices: []u16 = &.{},
    key_lookup: []identity.Handle = &.{},
    dimension_service: ?dimension_api.Service = null,
    active_count: usize = 0,
    free_count: usize = 0,

    pub fn create(allocator: std.mem.Allocator, configuration: Configuration) !*Worlds {
        try validateRuntimeConfiguration(configuration);
        const self = try preallocated.create(Worlds, allocator);
        self.* = .{ .configuration = configuration };
        self.records = try preallocated.alloc(World, allocator, config.max_worlds);
        self.generations = try preallocated.alloc(u16, allocator, config.max_worlds);
        self.occupied = try preallocated.alloc(bool, allocator, config.max_worlds);
        self.active_handles = try preallocated.alloc(identity.Handle, allocator, config.max_worlds);
        self.active_positions = try preallocated.alloc(u16, allocator, config.max_worlds);
        self.free_indices = try preallocated.alloc(u16, allocator, config.max_worlds);
        self.key_lookup = try preallocated.alloc(identity.Handle, allocator, config.max_worlds * 2);
        @memset(self.generations, 1);
        @memset(self.occupied, false);
        @memset(self.key_lookup, identity.invalid);
        self.initializeFreeList();
        for (configuration.initial) |description| _ = try self.add(description);
        return self;
    }

    pub fn add(self: *Worlds, description: Description) !identity.Handle {
        if (self.find(description.key) != null) return error.DuplicateWorldKey;
        if (description.name.len == 0 or description.name.len > config.max_world_name_bytes)
            return error.InvalidWorldName;
        for (self.active()) |handle|
            if (std.mem.eql(u8, self.getConst(handle).?.nameSlice(), description.name))
                return error.DuplicateWorldName;
        if (self.dimension_service) |registry|
            if (registry.definition(description.dimension) == null)
                return error.UnknownDimension;
        if (self.free_count == 0) return error.WorldCapacity;
        self.free_count -= 1;
        const index = self.free_indices[self.free_count];
        const handle = identity.Handle{ .index = index, .generation = self.generations[index] };
        self.records[index] = .{
            .key = description.key,
            .name = undefined,
            .name_len = @intCast(description.name.len),
            .dimension = description.dimension,
            .generator = description.generator,
            .seed = description.seed,
            .spawn_x = description.spawn_x,
            .spawn_y = description.spawn_y,
            .spawn_z = description.spawn_z,
            .border = description.border,
        };
        @memcpy(self.records[index].name[0..description.name.len], description.name);
        self.occupied[index] = true;
        self.active_positions[index] = @intCast(self.active_count);
        self.active_handles[self.active_count] = handle;
        self.active_count += 1;
        self.insertKey(handle);
        return handle;
    }

    pub fn destroy(self: *Worlds, handle: identity.Handle) !void {
        const world = self.get(handle) orelse return error.StaleWorldHandle;
        if (world.tickets != 0) return error.WorldInUse;
        self.removeKey(handle, world.key);
        const position: usize = self.active_positions[handle.index];
        self.active_count -= 1;
        if (position != self.active_count) {
            const moved = self.active_handles[self.active_count];
            self.active_handles[position] = moved;
            self.active_positions[moved.index] = @intCast(position);
        }
        self.occupied[handle.index] = false;
        self.generations[handle.index] +%= 1;
        if (self.generations[handle.index] == 0) self.generations[handle.index] = 1;
        self.free_indices[self.free_count] = handle.index;
        self.free_count += 1;
    }

    pub fn get(self: *Worlds, handle: identity.Handle) ?*World {
        if (handle.index >= self.records.len or
            !self.occupied[handle.index] or
            self.generations[handle.index] != handle.generation)
            return null;
        return &self.records[handle.index];
    }

    pub fn getConst(self: *const Worlds, handle: identity.Handle) ?*const World {
        if (handle.index >= self.records.len or
            !self.occupied[handle.index] or
            self.generations[handle.index] != handle.generation)
            return null;
        return &self.records[handle.index];
    }

    pub fn context(self: *Worlds, handle: identity.Handle) ?Context {
        return .{ .handle = handle, .world = self.get(handle) orelse return null };
    }

    pub fn find(self: *const Worlds, key: identity.Key) ?identity.Handle {
        const mask = self.key_lookup.len - 1;
        var probe = keyHash(key);
        for (0..self.key_lookup.len) |_| {
            const handle = self.key_lookup[probe & mask];
            if (!identity.valid(handle)) return null;
            if (self.records[handle.index].key.value == key.value) return handle;
            probe += 1;
        }
        return null;
    }

    pub fn active(self: *const Worlds) []const identity.Handle {
        return self.active_handles[0..self.active_count];
    }

    pub fn bindDimensions(self: *Worlds, registry: dimension_api.Service) !void {
        if (self.dimension_service != null) return error.DimensionRegistryAlreadyBound;
        if (registry.definitions.len == 0) return error.InvalidDimensionRegistry;
        for (self.active()) |handle| {
            const world = self.getConst(handle).?;
            if (registry.definition(world.dimension) == null)
                return error.UnknownDimension;
        }
        self.dimension_service = registry;
    }

    pub fn dimensionRegistry(self: *const Worlds) ?dimension_api.Service {
        return self.dimension_service;
    }

    fn initializeFreeList(self: *Worlds) void {
        self.free_count = self.free_indices.len;
        for (0..self.free_indices.len) |position|
            self.free_indices[position] = @intCast(self.free_indices.len - 1 - position);
    }

    fn insertKey(self: *Worlds, handle: identity.Handle) void {
        const mask = self.key_lookup.len - 1;
        var probe = keyHash(self.records[handle.index].key);
        for (0..self.key_lookup.len) |_| {
            const slot = &self.key_lookup[probe & mask];
            if (!identity.valid(slot.*)) {
                slot.* = handle;
                return;
            }
            probe += 1;
        }
        unreachable;
    }

    fn removeKey(self: *Worlds, handle: identity.Handle, key: identity.Key) void {
        const mask = self.key_lookup.len - 1;
        var hole = keyHash(key) & mask;
        for (0..self.key_lookup.len) |_| {
            if (self.key_lookup[hole].eql(handle)) break;
            std.debug.assert(identity.valid(self.key_lookup[hole]));
            hole = (hole + 1) & mask;
        } else unreachable;
        self.key_lookup[hole] = identity.invalid;
        var scan = (hole + 1) & mask;
        while (identity.valid(self.key_lookup[scan])) : (scan = (scan + 1) & mask) {
            const moved = self.key_lookup[scan];
            const ideal = keyHash(self.records[moved.index].key) & mask;
            if (probeDistance(ideal, hole, mask) < probeDistance(ideal, scan, mask)) {
                self.key_lookup[hole] = moved;
                self.key_lookup[scan] = identity.invalid;
                hole = scan;
            }
        }
    }
};

fn validateRuntimeConfiguration(configuration: Configuration) !void {
    if (configuration.initial.len > config.max_worlds) return error.WorldCapacity;
    for (configuration.initial, 0..) |world, index| {
        if (world.name.len == 0 or world.name.len > config.max_world_name_bytes)
            return error.InvalidWorldName;
        for (configuration.initial[0..index]) |previous| {
            if (previous.key.value == world.key.value) return error.DuplicateWorldKey;
            if (std.mem.eql(u8, previous.name, world.name)) return error.DuplicateWorldName;
        }
    }
}

fn keyHash(key: identity.Key) usize {
    var value: u64 = @truncate(key.value ^ (key.value >> 64));
    value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
    return @intCast(value ^ (value >> 31));
}

fn probeDistance(ideal: usize, actual: usize, mask: usize) usize {
    return (actual -% ideal) & mask;
}
