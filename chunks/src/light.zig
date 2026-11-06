const std = @import("std");
const zstandard = @import("zstandard");
const assert = std.debug.assert;

pub const maximum_sections = 32;
pub const layer_bytes = 2048;
pub const header_bytes = 222;
pub const maximum_bytes = header_bytes + 9 * maximum_sections * 128 + 2 * (maximum_sections + 2) * (1 + layer_bytes);
pub const algorithm_version: u32 = 2;
pub const batch_max = 4;

pub const Column = struct {
    world: u32,
    x: i32,
    z: i32,

    pub fn key(self: Column, kind: enum(u8) { revision, light }) [13]u8 {
        var bytes: [13]u8 = undefined;
        bytes[0] = @backingInt(kind);
        std.mem.writeInt(u32, bytes[1..5], self.world, .big);
        std.mem.writeInt(i32, bytes[5..9], self.x, .big);
        std.mem.writeInt(i32, bytes[9..13], self.z, .big);
        return bytes;
    }

    pub fn neighbors(self: Column) error{Overflow}![9]Column {
        var columns: [9]Column = undefined;
        for (&columns, 0..) |*column, index| column.* = .{
            .world = self.world,
            .x = try std.math.add(i32, self.x, @as(i32, @intCast(index % 3)) - 1),
            .z = try std.math.add(i32, self.z, @as(i32, @intCast(index / 3)) - 1),
        };
        return columns;
    }

    pub fn contains(self: Column, key_bytes: []const u8, minimum: i32, count: usize) bool {
        assert(key_bytes.len == 16 and count > 0);
        if (std.mem.readInt(u32, key_bytes[0..4], .big) != self.world) return false;
        const x = std.mem.readInt(i32, key_bytes[4..8], .big);
        const z = std.mem.readInt(i32, key_bytes[8..12], .big);
        const y = std.mem.readInt(i32, key_bytes[12..16], .big);
        return @abs(@as(i64, x) - self.x) <= 1 and @abs(@as(i64, z) - self.z) <= 1 and y >= minimum and @as(i64, y) - minimum < count;
    }
};

pub const Snapshot = struct { length: ?usize, revisions: [9]u64, clean: bool };
pub const Request = struct { column: Column, minimum: i32, count: usize, destination: ?[]u8 };

pub const Header = struct {
    rules: [32]u8,
    minimum: i32,
    count: u8,
    skylight: bool,
    coverage: u32,
    revisions: [9]u64,
    biomes: [9]u32,
    uniform: u32 = 0,
    states: [maximum_sections]u16 = @splat(0),
};

pub const Layer = union(enum) {
    uniform: u4,
    dense: *const [layer_bytes]u8,

    pub fn write(self: Layer, output: *[layer_bytes]u8) void {
        switch (self) {
            .uniform => |level| @memset(output, @as(u8, level) * 17),
            .dense => |bytes| @memcpy(output, bytes),
        }
    }

    pub fn nonzero(self: Layer) bool {
        return switch (self) {
            .uniform => |level| level != 0,
            .dense => true,
        };
    }
};

pub const View = struct {
    header: Header,
    layers: [2][maximum_sections + 2]Layer = undefined,
    masks: [2]u64 = .{ 0, 0 },
    biomes: [9][maximum_sections]?*const [128]u8 = @splat(@splat(null)),
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    compressor: zstandard.Compressor,
    decompressor: zstandard.Decompressor,
    raw: []u8,
    frame: []u8,
    cursor: usize = 0,
    sections: usize = 0,
    written: usize = 0,
    biome_count: usize = 0,
    reserved: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Workspace {
        var compressor = try zstandard.Compressor.init(allocator, 6, maximum_bytes);
        errdefer compressor.deinit();
        var decompressor = try zstandard.Decompressor.init(allocator);
        errdefer decompressor.deinit();
        const raw = try allocator.alloc(u8, maximum_bytes);
        errdefer allocator.free(raw);
        const frame = try allocator.alloc(u8, zstandard.bound(maximum_bytes));
        return .{
            .allocator = allocator,
            .compressor = compressor,
            .decompressor = decompressor,
            .raw = raw,
            .frame = frame,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.compressor.deinit();
        self.decompressor.deinit();
        self.allocator.free(self.raw);
        self.allocator.free(self.frame);
        self.* = undefined;
    }

    pub fn begin(self: *Workspace, header: Header) void {
        assert(header.count > 0 and header.count <= maximum_sections);
        assert(header.count == 32 or header.coverage >> @intCast(header.count) == 0);
        @memcpy(self.raw[0..4], "LRL2");
        @memcpy(self.raw[4..36], &header.rules);
        std.mem.writeInt(i32, self.raw[36..40], header.minimum, .little);
        self.raw[40] = header.count;
        self.raw[41] = @intFromBool(header.skylight);
        std.mem.writeInt(u32, self.raw[42..46], header.coverage, .little);
        for (header.revisions, 0..) |revision, index| std.mem.writeInt(u64, self.raw[46 + index * 8 ..][0..8], revision, .little);
        self.biome_count = 0;
        for (header.biomes, 0..) |bits, index| {
            assert(header.count == 32 or bits >> @intCast(header.count) == 0);
            std.mem.writeInt(u32, self.raw[118 + index * 4 ..][0..4], bits, .little);
            self.biome_count += @popCount(bits);
        }
        assert(header.count == 32 or header.uniform >> @intCast(header.count) == 0);
        std.mem.writeInt(u32, self.raw[154..158], header.uniform, .little);
        for (header.states, 0..) |state, index| std.mem.writeInt(u16, self.raw[158 + index * 2 ..][0..2], state, .little);
        self.cursor = header_bytes;
        self.sections = @as(usize, header.count) + 2;
        self.written = 0;
        self.reserved = false;
    }

    pub fn biome(self: *Workspace, values: *const [64]u16) void {
        assert(self.biome_count > 0 and self.written == 0 and !self.reserved);
        assert(self.cursor + 128 <= self.raw.len);
        for (values, 0..) |value, index| std.mem.writeInt(u16, self.raw[self.cursor + index * 2 ..][0..2], value, .little);
        self.cursor += 128;
        self.biome_count -= 1;
    }

    pub fn section(self: *Workspace) *[layer_bytes]u8 {
        assert(!self.reserved and self.biome_count == 0 and self.written < 2 * self.sections);
        assert(self.cursor + 1 + layer_bytes <= self.raw.len);
        self.reserved = true;
        return self.raw[self.cursor + 1 ..][0..layer_bytes];
    }

    pub fn commitSection(self: *Workspace) void {
        assert(self.reserved);
        const bytes = self.raw[self.cursor + 1 ..][0..layer_bytes];
        const first = bytes[0];
        const uniform = first & 15 == first >> 4 and std.mem.allEqual(u8, bytes, first);
        self.raw[self.cursor] = if (uniform) first & 15 else 16;
        self.cursor += if (uniform) 1 else 1 + layer_bytes;
        self.written += 1;
        self.reserved = false;
    }

    pub fn finish(self: *Workspace) ![]const u8 {
        assert(!self.reserved and self.written == 2 * self.sections);
        return self.compressor.encode(self.raw[0..self.cursor], self.frame);
    }

    pub fn decode(self: *Workspace, frame: []const u8) !View {
        const raw = try self.decompressor.decode(frame, self.raw);
        if (raw.len < 4) return error.Corrupt;
        if (!std.mem.eql(u8, raw[0..4], "LRL2")) return error.Outdated;
        if (raw.len < header_bytes) return error.Corrupt;
        const count = raw[40];
        if (count == 0 or count > maximum_sections or raw[41] > 1) return error.Corrupt;
        const coverage = std.mem.readInt(u32, raw[42..46], .little);
        if (count < 32 and coverage >> @intCast(count) != 0) return error.Corrupt;
        var view: View = .{ .header = .{
            .rules = raw[4..36].*,
            .minimum = std.mem.readInt(i32, raw[36..40], .little),
            .count = count,
            .skylight = raw[41] != 0,
            .coverage = coverage,
            .revisions = undefined,
            .biomes = undefined,
            .uniform = std.mem.readInt(u32, raw[154..158], .little),
            .states = undefined,
        } };
        if (count < 32 and view.header.uniform >> @intCast(count) != 0) return error.Corrupt;
        for (&view.header.states, 0..) |*state, index| state.* = std.mem.readInt(u16, raw[158 + index * 2 ..][0..2], .little);
        for (&view.header.revisions, 0..) |*revision, index| revision.* = std.mem.readInt(u64, raw[46 + index * 8 ..][0..8], .little);
        var cursor: usize = header_bytes;
        for (&view.header.biomes, 0..) |*bits, column| {
            bits.* = std.mem.readInt(u32, raw[118 + column * 4 ..][0..4], .little);
            if (count < 32 and bits.* >> @intCast(count) != 0) return error.Corrupt;
            for (0..count) |section_index| {
                if (bits.* & (@as(u32, 1) << @intCast(section_index)) == 0) continue;
                if (raw.len - cursor < 128) return error.Corrupt;
                view.biomes[column][section_index] = raw[cursor..][0..128];
                cursor += 128;
            }
        }
        for (0..2) |layer| for (0..@as(usize, count) + 2) |section_index| {
            if (cursor == raw.len) return error.Corrupt;
            const tag = raw[cursor];
            cursor += 1;
            const value: Layer = if (tag < 16) .{ .uniform = @intCast(tag) } else dense: {
                if (tag != 16 or raw.len - cursor < layer_bytes) return error.Corrupt;
                const bytes = raw[cursor..][0..layer_bytes];
                cursor += layer_bytes;
                break :dense .{ .dense = bytes };
            };
            view.layers[layer][section_index] = value;
            if (value.nonzero()) view.masks[layer] |= @as(u64, 1) << @intCast(section_index);
        };
        if (cursor != raw.len) return error.Corrupt;
        return view;
    }
};

test "stored lighting preserves uniform and dense planes biomes and dependency revisions without allocation" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var workspace = try Workspace.init(bounded.allocator());
    defer workspace.deinit();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var header: Header = .{ .rules = @splat(0x73), .minimum = -4, .count = 3, .skylight = true, .coverage = 7, .revisions = .{ 4, 5, 6, 7, 8, 9, 10, 11, 12 }, .biomes = .{ 1, 0, 0, 0, 4, 0, 0, 0, 0 }, .uniform = 5 };
    header.states[0] = 42;
    header.states[2] = 59999;
    workspace.begin(header);
    const cells: [64]u16 = @splat(300);
    workspace.biome(&cells);
    workspace.biome(&cells);
    for (0..10) |section_index| {
        const output = workspace.section();
        if (section_index == 2) {
            for (output, 0..) |*byte, index| byte.* = @truncate(index);
        } else @memset(output, if (section_index < 5) 0 else 255);
        workspace.commitSection();
    }
    const frame = try workspace.finish();
    const view = try workspace.decode(frame);
    try std.testing.expectEqualDeep(header, view.header);
    try std.testing.expectEqual([2]u64{ 4, 31 }, view.masks);
    try std.testing.expect(view.biomes[0][0] != null and view.biomes[4][2] != null and view.biomes[1][0] == null);
    for (0..64) |index| try std.testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, view.biomes[4][2].?[index * 2 ..][0..2], .little));
    var bytes: [2048]u8 = undefined;
    view.layers[0][2].write(&bytes);
    for (bytes, 0..) |byte, index| try std.testing.expectEqual(@as(u8, @truncate(index)), byte);
    view.layers[1][2].write(&bytes);
    try std.testing.expect(std.mem.allEqual(u8, &bytes, 255));
    try std.testing.expect(!bounded.has_induced_failure);
}

test "stored lighting rejects invalid dimensions truncated planes and trailing data" {
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const header: Header = .{ .rules = @splat(0), .minimum = 0, .count = 1, .skylight = false, .coverage = 1, .revisions = @splat(0), .biomes = @splat(0) };
    for (0..6) |case| {
        workspace.begin(header);
        for (0..6) |_| {
            @memset(workspace.section(), 0);
            workspace.commitSection();
        }
        switch (case) {
            0 => workspace.raw[40] = maximum_sections + 1,
            1 => workspace.raw[header_bytes] = 17,
            2 => workspace.cursor -= 1,
            3 => {
                workspace.raw[workspace.cursor] = 0;
                workspace.cursor += 1;
            },
            4 => @memcpy(workspace.raw[0..4], "LRL9"),
            5 => std.mem.writeInt(u32, workspace.raw[154..158], 2, .little),
            else => unreachable,
        }
        const frame = try workspace.compressor.encode(workspace.raw[0..workspace.cursor], workspace.frame);
        if (case == 4) try std.testing.expectError(error.Outdated, workspace.decode(frame)) else try std.testing.expectError(error.Corrupt, workspace.decode(frame));
    }
}
