const std = @import("std");
const storage = @import("storage");

pub const Worlds = struct {
    pub const id = "minecraft:worlds";

    pub const Dimension = enum(u8) {
        overworld = 0,
        nether = 1,
        end = 2,

        pub fn typeId(self: Dimension) i32 {
            return switch (self) {
                .overworld => 0,
                .nether => 3,
                .end => 2,
            };
        }

        pub fn minimumSection(self: Dimension) i32 {
            return if (self == .overworld) -4 else 0;
        }

        pub fn sectionCount(self: Dimension) usize {
            return if (self == .overworld) 24 else 16;
        }
    };

    pub const Definition = struct {
        name: []const u8,
        dimension: Dimension,
    };

    pub const World = struct {
        id: u32,
        name: []const u8,
        dimension: Dimension,
    };

    pub const Configuration = struct { maximum: usize = 16 };

    pub const Dependencies = struct { storage: storage.Namespace };

    entries: []World,
    labels: [][64]u8,
    name_storage: [][]const u8,
    names: []const []const u8,
    count: usize = 0,
    checkpointed: usize = 0,
    next_id: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Worlds {
        if (config.maximum == 0 or config.maximum > 16) return error.InvalidWorldCapacity;

        const self = try allocator.create(Worlds);
        const names = try allocator.alloc([]const u8, config.maximum);
        self.* = .{
            .entries = try allocator.alloc(World, config.maximum),
            .labels = try allocator.alloc([64]u8, config.maximum),
            .name_storage = names,
            .names = names[0..0],
        };
        var encoded: [1126]u8 = undefined;
        if (try deps.storage.get("catalog", &encoded)) |length| {
            if (length < 6 or !std.mem.eql(u8, encoded[0..5], "LRWD\x01") or encoded[5] > 16 or length != 6 + @as(usize, encoded[5]) * 70)
                return error.CorruptWorldCatalog;
            if (encoded[5] > config.maximum) return error.WorldCapacity;

            for (0..encoded[5]) |index| {
                const entry = encoded[6 + index * 70 ..][0..70];
                if (entry[5] == 0 or entry[5] > 64) return error.CorruptWorldCatalog;

                const name = entry[6..][0..entry[5]];
                validateName(name) catch return error.CorruptWorldCatalog;
                const world_id = std.mem.readInt(u32, entry[0..4], .little);
                const dimension = std.enums.fromInt(Dimension, entry[4]) orelse return error.CorruptWorldCatalog;

                for (self.entries[0..index]) |previous|
                    if (previous.id == world_id or std.mem.eql(u8, previous.name, name)) return error.CorruptWorldCatalog;
                @memcpy(self.labels[index][0..name.len], name);
                names[index] = self.labels[index][0..name.len];
                self.entries[index] = .{ .id = world_id, .name = names[index], .dimension = dimension };
                self.next_id = @max(self.next_id, @as(u64, world_id) + 1);
            }

            self.count = encoded[5];
            self.checkpointed = self.count;
            self.names = names[0..self.count];
        }

        return self;
    }

    /// Idempotent by name. Copies the name into reserved storage. No runtime allocation is needed.
    /// Creation becomes durable with the containing tick's checkpoint.
    pub fn create(self: *Worlds, definition: Definition) !u32 {
        try validateName(definition.name);
        if (self.find(definition.name)) |world| {
            if (world.dimension != definition.dimension) return error.WorldIdentityChanged;
            return world.id;
        }

        if (self.count == self.entries.len) return error.WorldCapacity;
        if (self.next_id > std.math.maxInt(u32)) return error.WorldIdExhausted;

        const world_id: u32 = @intCast(self.next_id);
        const name = self.labels[self.count][0..definition.name.len];
        @memcpy(name, definition.name);
        self.entries[self.count] = .{ .id = world_id, .name = name, .dimension = definition.dimension };
        self.name_storage[self.count] = name;
        self.count += 1;
        self.next_id += 1;
        self.names = self.name_storage[0..self.count];
        return world_id;
    }

    pub fn get(self: *const Worlds, world_id: u32) ?World {
        for (self.all()) |world| if (world.id == world_id) return world;
        return null;
    }

    pub fn find(self: *const Worlds, name: []const u8) ?World {
        for (self.all()) |world| if (std.mem.eql(u8, world.name, name)) return world;
        return null;
    }

    pub fn all(self: *const Worlds) []const World {
        return self.entries[0..self.count];
    }

    pub fn checkpoint(self: *Worlds, namespace: storage.Namespace) !void {
        if (self.checkpointed == self.count) return;

        var encoded: [1126]u8 = @splat(0);
        @memcpy(encoded[0..5], "LRWD\x01");
        encoded[5] = @intCast(self.count);

        for (self.all(), 0..) |world, index| {
            const entry = encoded[6 + index * 70 ..][0..70];
            std.mem.writeInt(u32, entry[0..4], world.id, .little);
            entry[4] = @intFromEnum(world.dimension);
            entry[5] = @intCast(world.name.len);
            @memcpy(entry[6..][0..world.name.len], world.name);
        }

        try namespace.put("catalog", encoded[0 .. 6 + self.count * 70]);
        self.checkpointed = self.count;
    }
};

fn validateName(name: []const u8) !void {
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return error.InvalidWorldName;
    if (colon == 0 or colon + 1 == name.len or name.len > 64) return error.InvalidWorldName;

    for (name, 0..) |byte, offset| {
        if (offset == colon) continue;
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and std.mem.indexOfScalar(u8, "_.-", byte) == null and !(byte == '/' and offset > colon))
            return error.InvalidWorldName;
    }
}
