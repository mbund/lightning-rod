const std = @import("std");
const storage = @import("storage");

pub const Worlds = struct {
    pub const id = "minecraft:worlds";

    pub const Dimension = struct {
        name: []const u8,
        minimum_section: i32,
        section_count: u16,
        skylight: bool = false,

        pub fn minimumSection(self: Dimension) i32 {
            return self.minimum_section;
        }

        pub fn sectionCount(self: Dimension) usize {
            return self.section_count;
        }

        pub fn eql(self: Dimension, other: Dimension) bool {
            return std.mem.eql(u8, self.name, other.name) and self.minimum_section == other.minimum_section and
                self.section_count == other.section_count and self.skylight == other.skylight;
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
    dimension_labels: [][64]u8,
    encoded: []u8,
    name_storage: [][]const u8,
    names: []const []const u8,
    count: usize = 0,
    checkpointed: usize = 0,
    next_id: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Worlds {
        if (config.maximum == 0 or config.maximum > std.math.maxInt(u16)) return error.InvalidWorldCapacity;

        const self = try allocator.create(Worlds);
        const names = try allocator.alloc([]const u8, config.maximum);
        self.* = .{
            .entries = try allocator.alloc(World, config.maximum),
            .labels = try allocator.alloc([64]u8, config.maximum),
            .dimension_labels = try allocator.alloc([64]u8, config.maximum),
            .encoded = try allocator.alloc(u8, 7 + config.maximum * 140),
            .name_storage = names,
            .names = names[0..0],
        };
        const encoded = self.encoded;
        if (try deps.storage.get("catalog", encoded)) |length| {
            if (length < 5 or !std.mem.eql(u8, encoded[0..4], "LRWD")) return error.CorruptWorldCatalog;
            if (encoded[4] != 2) return error.UnsupportedWorldCatalog;
            if (length < 7) return error.CorruptWorldCatalog;
            const count = std.mem.readInt(u16, encoded[5..7], .little);
            if (count > config.maximum) return error.WorldCapacity;
            if (length != 7 + @as(usize, count) * 140) return error.CorruptWorldCatalog;

            for (0..count) |index| {
                const entry = encoded[7 + index * 140 ..][0..140];
                if (entry[10] == 0 or entry[10] > 64 or entry[11] == 0 or entry[11] > 64) return error.CorruptWorldCatalog;

                const name = entry[12..][0..entry[10]];
                validateName(name) catch return error.CorruptWorldCatalog;
                const world_id = std.mem.readInt(u32, entry[0..4], .little);
                const dimension: Dimension = .{
                    .name = entry[76..][0..entry[11]],
                    .minimum_section = std.mem.readInt(i32, entry[4..8], .little),
                    .section_count = std.mem.readInt(u16, entry[8..10], .little) & 0x7fff,
                    .skylight = entry[9] & 0x80 != 0,
                };
                validateDimension(dimension) catch return error.CorruptWorldCatalog;

                for (self.entries[0..index]) |previous| {
                    if (previous.id == world_id or std.mem.eql(u8, previous.name, name)) return error.CorruptWorldCatalog;
                    if (std.mem.eql(u8, previous.dimension.name, dimension.name) and !previous.dimension.eql(dimension)) return error.CorruptWorldCatalog;
                }
                @memcpy(self.labels[index][0..name.len], name);
                @memcpy(self.dimension_labels[index][0..dimension.name.len], dimension.name);
                names[index] = self.labels[index][0..name.len];
                self.entries[index] = .{ .id = world_id, .name = names[index], .dimension = dimension };
                self.entries[index].dimension.name = self.dimension_labels[index][0..dimension.name.len];
                self.next_id = @max(self.next_id, @as(u64, world_id) + 1);
            }

            self.count = count;
            self.checkpointed = self.count;
            self.names = names[0..self.count];
        }

        return self;
    }

    /// Idempotent by name. Copies the name into reserved storage. No runtime allocation is needed.
    /// Creation becomes durable with the containing tick's checkpoint.
    pub fn create(self: *Worlds, definition: Definition) !u32 {
        try validateName(definition.name);
        try validateDimension(definition.dimension);
        if (self.find(definition.name)) |world| {
            if (!world.dimension.eql(definition.dimension)) return error.WorldIdentityChanged;
            return world.id;
        }

        for (self.all()) |world| {
            if (std.mem.eql(u8, world.dimension.name, definition.dimension.name) and !world.dimension.eql(definition.dimension))
                return error.DimensionIdentityChanged;
        }

        if (self.count == self.entries.len) return error.WorldCapacity;
        if (self.next_id > std.math.maxInt(u32)) return error.WorldIdExhausted;

        const world_id: u32 = @intCast(self.next_id);
        const name = self.labels[self.count][0..definition.name.len];
        @memcpy(name, definition.name);
        const dimension_name = self.dimension_labels[self.count][0..definition.dimension.name.len];
        @memcpy(dimension_name, definition.dimension.name);
        self.entries[self.count] = .{ .id = world_id, .name = name, .dimension = definition.dimension };
        self.entries[self.count].dimension.name = dimension_name;
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

        const encoded = self.encoded[0 .. 7 + self.count * 140];
        @memset(encoded, 0);
        @memcpy(encoded[0..5], "LRWD\x02");
        std.mem.writeInt(u16, encoded[5..7], @intCast(self.count), .little);

        for (self.all(), 0..) |world, index| {
            const entry = encoded[7 + index * 140 ..][0..140];
            std.mem.writeInt(u32, entry[0..4], world.id, .little);
            std.mem.writeInt(i32, entry[4..8], world.dimension.minimum_section, .little);
            std.mem.writeInt(u16, entry[8..10], world.dimension.section_count | (if (world.dimension.skylight) @as(u16, 0x8000) else 0), .little);
            entry[10] = @intCast(world.name.len);
            entry[11] = @intCast(world.dimension.name.len);
            @memcpy(entry[12..][0..world.name.len], world.name);
            @memcpy(entry[76..][0..world.dimension.name.len], world.dimension.name);
        }

        try namespace.put("catalog", encoded);
        self.checkpointed = self.count;
    }
};

fn validateDimension(dimension: Worlds.Dimension) !void {
    try validateName(dimension.name);
    if (dimension.section_count == 0 or dimension.section_count > 0x7fff or dimension.minimum_section < @divExact(std.math.minInt(i32), 16) or
        @as(i64, dimension.minimum_section) + dimension.section_count > @divFloor(std.math.maxInt(i32), 16)) return error.InvalidDimension;
}

fn validateName(name: []const u8) !void {
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return error.InvalidWorldName;
    if (colon == 0 or colon + 1 == name.len or name.len > 64) return error.InvalidWorldName;

    for (name, 0..) |byte, offset| {
        if (offset == colon) continue;
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and std.mem.indexOfScalar(u8, "_.-", byte) == null and !(byte == '/' and offset > colon))
            return error.InvalidWorldName;
    }
}
