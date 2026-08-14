const std = @import("std");
const mcc = @import("minecraft_conformance");

const net = std.Io.net;

pub const ChunkSnapshot = struct {
    chunk_x: i32,
    chunk_z: i32,
    min_y: i32,
    height: u32,
    block_palette: [][]u8,
    blocks: []u32,
    biome_palette: [][]u8,
    biomes: []u32,

    pub fn deinit(self: *ChunkSnapshot, allocator: std.mem.Allocator) void {
        for (self.block_palette) |entry| allocator.free(entry);
        allocator.free(self.block_palette);
        allocator.free(self.blocks);
        for (self.biome_palette) |entry| allocator.free(entry);
        allocator.free(self.biome_palette);
        allocator.free(self.biomes);
        self.* = undefined;
    }
};

/// Zig side of the private Vanilla Fabric integration. The public boundary is
/// still `mcc.Adapter`; the byte exchange below is deliberately local
/// to this implementation and is not a conformance artifact or target API.
pub const VanillaAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: net.Stream,
    read_buffer: []u8,
    write_buffer: []u8,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    clients: []const mcc.Client = &.{},
    identities: [64]mcc.Identity = undefined,
    identity_count: usize = 0,
    outputs: std.ArrayListUnmanaged(mcc.Adapter.Output) = .empty,
    payloads: std.ArrayListUnmanaged([]u8) = .empty,
    closed: bool = false,

    const restore_command: u8 = 1;
    const stage_command: u8 = 2;
    const step_command: u8 = 3;
    const shutdown_command: u8 = 4;
    const control_command: u8 = 5;
    const snapshot_chunk_command: u8 = 6;
    const snapshot_noise_chunk_command: u8 = 7;
    const snapshot_surface_chunk_command: u8 = 8;
    const snapshot_carvers_chunk_command: u8 = 9;
    const snapshot_features_chunk_command: u8 = 10;
    const feature_indices_command: u8 = 11;

    pub fn connect(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) !VanillaAdapter {
        const address = try net.UnixAddress.init(socket_path);
        const stream = try address.connect(io);
        errdefer stream.close(io);
        const read_buffer = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(read_buffer);
        const write_buffer = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(write_buffer);
        return .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .reader = .init(stream, io, read_buffer),
            .writer = .init(stream, io, write_buffer),
        };
    }

    pub fn targetInfo() mcc.TargetInfo {
        return .{
            .name = "vanilla-1.21.8-fabric-harness",
            .kind = .vanilla,
            .minecraft = "1.21.8",
            .capabilities = mcc.black_box_capabilities,
        };
    }

    pub fn deinit(self: *VanillaAdapter) void {
        self.clearOutputs();
        self.outputs.deinit(self.allocator);
        self.payloads.deinit(self.allocator);
        if (!self.closed) {
            self.writer.interface.writeByte(shutdown_command) catch {};
            self.writer.interface.flush() catch {};
            _ = self.readStatus() catch {};
            self.stream.close(self.io);
        }
        self.allocator.free(self.write_buffer);
        self.allocator.free(self.read_buffer);
        self.* = undefined;
    }

    pub fn adapter(self: *VanillaAdapter) mcc.Adapter {
        return .{ .context = self, .vtable = &.{ .restore = restore, .restart = restart, .stage = stage, .control = control, .step = step } };
    }

    pub fn snapshotChunk(self: *VanillaAdapter, chunk_x: i32, chunk_z: i32) !ChunkSnapshot {
        return self.readChunkSnapshot(snapshot_chunk_command, chunk_x, chunk_z);
    }

    pub fn snapshotNoiseChunk(self: *VanillaAdapter, chunk_x: i32, chunk_z: i32) !ChunkSnapshot {
        return self.readChunkSnapshot(snapshot_noise_chunk_command, chunk_x, chunk_z);
    }

    pub fn snapshotSurfaceChunk(self: *VanillaAdapter, chunk_x: i32, chunk_z: i32) !ChunkSnapshot {
        return self.readChunkSnapshot(snapshot_surface_chunk_command, chunk_x, chunk_z);
    }

    pub fn snapshotCarversChunk(self: *VanillaAdapter, chunk_x: i32, chunk_z: i32) !ChunkSnapshot {
        return self.readChunkSnapshot(snapshot_carvers_chunk_command, chunk_x, chunk_z);
    }

    pub fn snapshotFeaturesChunk(self: *VanillaAdapter, chunk_x: i32, chunk_z: i32) !ChunkSnapshot {
        return self.readChunkSnapshot(snapshot_features_chunk_command, chunk_x, chunk_z);
    }

    pub fn featureIndices(self: *VanillaAdapter) ![][]u8 {
        try self.writer.interface.writeByte(feature_indices_command);
        try self.writer.interface.flush();
        try self.readStatus();
        const count = try self.readCount(65_536);
        const entries = try self.allocator.alloc([]u8, count);
        errdefer self.allocator.free(entries);
        var initialized: usize = 0;
        errdefer for (entries[0..initialized]) |entry| self.allocator.free(entry);
        for (entries) |*entry| {
            entry.* = try self.readStringAlloc(1024 * 1024);
            initialized += 1;
        }
        return entries;
    }

    fn readChunkSnapshot(self: *VanillaAdapter, command: u8, chunk_x: i32, chunk_z: i32) !ChunkSnapshot {
        try self.writer.interface.writeByte(command);
        try writeI32(&self.writer.interface, chunk_x);
        try writeI32(&self.writer.interface, chunk_z);
        try self.writer.interface.flush();
        try self.readStatus();

        const returned_x = try self.reader.interface.takeInt(i32, .big);
        const returned_z = try self.reader.interface.takeInt(i32, .big);
        if (returned_x != chunk_x or returned_z != chunk_z) return error.VanillaHarnessChunkMismatch;
        const min_y = try self.reader.interface.takeInt(i32, .big);
        const height_i32 = try self.reader.interface.takeInt(i32, .big);
        if (height_i32 <= 0 or height_i32 > 4096 or height_i32 & 3 != 0) return error.InvalidVanillaWorldHeight;
        const height: u32 = @intCast(height_i32);

        const block_palette = try self.readPalette(65_536);
        errdefer freePalette(self.allocator, block_palette);
        const expected_blocks = std.math.mul(usize, 16 * 16, height) catch return error.InvalidVanillaChunkSize;
        const block_count = try self.readCount(expected_blocks);
        if (block_count != expected_blocks) return error.InvalidVanillaChunkSize;
        const blocks = try self.allocator.alloc(u32, block_count);
        errdefer self.allocator.free(blocks);
        for (blocks) |*block| {
            const value = try self.reader.interface.takeInt(i32, .big);
            if (value < 0 or value >= block_palette.len) return error.InvalidVanillaPaletteIndex;
            block.* = @intCast(value);
        }

        const biome_palette = try self.readPalette(4_096);
        errdefer freePalette(self.allocator, biome_palette);
        const expected_biomes = std.math.mul(usize, 4 * 4, height / 4) catch return error.InvalidVanillaChunkSize;
        const biome_count = try self.readCount(expected_biomes);
        if (biome_count != expected_biomes) return error.InvalidVanillaChunkSize;
        const biomes = try self.allocator.alloc(u32, biome_count);
        errdefer self.allocator.free(biomes);
        for (biomes) |*biome| {
            const value = try self.reader.interface.takeInt(i32, .big);
            if (value < 0 or value >= biome_palette.len) return error.InvalidVanillaPaletteIndex;
            biome.* = @intCast(value);
        }

        return .{
            .chunk_x = returned_x,
            .chunk_z = returned_z,
            .min_y = min_y,
            .height = height,
            .block_palette = block_palette,
            .blocks = blocks,
            .biome_palette = biome_palette,
            .biomes = biomes,
        };
    }

    fn from(context: *anyopaque) *VanillaAdapter {
        return @ptrCast(@alignCast(context));
    }

    fn restore(context: *anyopaque, definition: mcc.fixture.Definition, clients: []const mcc.Client) ![]const mcc.Identity {
        const self = from(context);
        if (clients.len > self.identities.len) return error.TooManyClients;
        self.clients = clients;

        const writer = &self.writer.interface;
        try writer.writeByte(restore_command);
        try writeString(writer, definition.id);
        try writeU64(writer, definition.seed);
        try writeI64(writer, definition.frozen_time);
        try writeCount(writer, clients.len);
        for (clients) |client| try writeString(writer, client.name);
        try writeCount(writer, definition.setup.len);
        for (definition.setup) |setup| switch (setup) {
            .set_block => |block| {
                try writer.writeByte(0);
                try writeI32(writer, block.x);
                try writeI16(writer, block.y);
                try writeI32(writer, block.z);
                try writeString(writer, block.state);
            },
            .fill_box => |box| {
                try writer.writeByte(7);
                try writeI32(writer, box.min_x);
                try writeI16(writer, box.min_y);
                try writeI32(writer, box.min_z);
                try writeI32(writer, box.max_x);
                try writeI16(writer, box.max_y);
                try writeI32(writer, box.max_z);
                try writeString(writer, box.state);
            },
            .spawn_player => |player| {
                try writer.writeByte(1);
                try writeString(writer, player.id);
                try writeF64(writer, player.x);
                try writeF64(writer, player.y);
                try writeF64(writer, player.z);
            },
            .spawn_entity => |entity| {
                try writer.writeByte(2);
                try writeString(writer, entity.id);
                try writeString(writer, entity.kind);
                try writeF64(writer, entity.x);
                try writeF64(writer, entity.y);
                try writeF64(writer, entity.z);
                try writer.writeByte(@intFromBool(entity.baby));
                try writer.writeByte(@intFromBool(entity.on_ground));
            },
            .spawn_item => |item| {
                try writer.writeByte(13);
                try writeString(writer, item.id);
                try writeString(writer, item.item);
                try writer.writeByte(item.count);
                try writeF64(writer, item.x);
                try writeF64(writer, item.y);
                try writeF64(writer, item.z);
                try writeF64(writer, item.velocity_x);
                try writeF64(writer, item.velocity_y);
                try writeF64(writer, item.velocity_z);
                try writer.writeInt(u16, item.pickup_delay, .big);
                try writer.writeInt(u32, item.age, .big);
            },
            .set_player_health => |entry| {
                try writer.writeByte(9);
                try writeString(writer, entry.id);
                try writeF32(writer, entry.health);
            },
            .set_entity_health => |entry| {
                try writer.writeByte(10);
                try writeString(writer, entry.id);
                try writeF32(writer, entry.health);
            },
            .set_player_gamemode => |entry| {
                try writer.writeByte(11);
                try writeString(writer, entry.id);
                try writeString(writer, entry.gamemode);
            },
            .set_held_stack => |held| {
                try writer.writeByte(3);
                try writeString(writer, held.id);
                try writeString(writer, held.item);
                try writer.writeByte(held.count);
            },
            .set_inventory_stack => |entry| {
                try writer.writeByte(5);
                try writeString(writer, entry.id);
                try writeString(writer, entry.slot);
                try writeString(writer, entry.item);
                try writer.writeByte(entry.count);
            },
            .set_selected_hotbar_slot => |entry| {
                try writer.writeByte(6);
                try writeString(writer, entry.id);
                try writer.writeByte(entry.slot);
            },
            .set_gamerule => |rule| {
                try writer.writeByte(4);
                try writeString(writer, rule.name);
                try writeString(writer, rule.value);
            },
            .set_time => |value| {
                try writer.writeByte(8);
                try writeI64(writer, value);
            },
            .enable_chunk_streaming => try writer.writeByte(12),
        };
        try writer.flush();
        try self.readStatus();

        const count = try self.readCount(64);
        if (count < clients.len or count > self.identities.len) return error.IdentityCountMismatch;
        for (0..count) |index| {
            const alias = try self.readStringAlloc(1024);
            defer self.allocator.free(alias);
            const stable_alias = if (index < clients.len) blk: {
                if (!std.mem.eql(u8, alias, clients[index].name)) return error.IdentityOrderMismatch;
                break :blk clients[index].name;
            } else fixtureIdentityAlias(definition, alias) orelse return error.UnknownFixtureIdentity;
            const entity_id = try self.reader.interface.takeInt(i32, .big);
            const uuid_high = try self.reader.interface.takeInt(u64, .big);
            const uuid_low = try self.reader.interface.takeInt(u64, .big);
            const uuid = (@as(u128, uuid_high) << 64) | uuid_low;
            const x = try self.readF64();
            const y = try self.readF64();
            const z = try self.readF64();
            self.identities[index] = .{
                .alias = stable_alias,
                .entity_id = entity_id,
                .uuid = uuid,
                .position = .{ x, y, z },
                .position_known = true,
            };
        }
        self.identity_count = count;
        return self.identities[0..count];
    }

    fn stage(context: *anyopaque, client: []const u8, packet_body: []const u8) !void {
        const self = from(context);
        const writer = &self.writer.interface;
        try writer.writeByte(stage_command);
        try writeString(writer, client);
        try writeCount(writer, packet_body.len);
        try writer.writeAll(packet_body);
        try writer.flush();
        try self.readStatus();
    }

    fn restart(_: *anyopaque) ![]const mcc.Identity {
        return error.RestartUnsupported;
    }

    fn control(context: *anyopaque, client: []const u8, kind: mcc.Control) !void {
        const self = from(context);
        try self.writer.interface.writeByte(control_command);
        try writeString(&self.writer.interface, client);
        try self.writer.interface.writeByte(@intFromEnum(kind));
        try self.writer.interface.flush();
        try self.readStatus();
    }

    fn step(context: *anyopaque) ![]const mcc.Adapter.Output {
        const self = from(context);
        self.clearOutputs();
        try self.writer.interface.writeByte(step_command);
        try self.writer.interface.flush();
        try self.readStatus();
        const count = try self.readCount(16 * 1024);
        try self.outputs.ensureTotalCapacity(self.allocator, count);
        try self.payloads.ensureTotalCapacity(self.allocator, count);
        for (0..count) |_| {
            const recipient_text = try self.readStringAlloc(1024);
            defer self.allocator.free(recipient_text);
            const recipient = self.clientName(recipient_text) orelse return error.UnknownOutputRecipient;
            const body_len = try self.readCount(16 * 1024 * 1024);
            const body = try self.allocator.alloc(u8, body_len);
            errdefer self.allocator.free(body);
            try self.reader.interface.readSliceAll(body);
            try self.payloads.append(self.allocator, body);
            try self.outputs.append(self.allocator, .{ .recipient = recipient, .payload = body });
        }
        return self.outputs.items;
    }

    fn clearOutputs(self: *VanillaAdapter) void {
        for (self.payloads.items) |payload| self.allocator.free(payload);
        self.payloads.clearRetainingCapacity();
        self.outputs.clearRetainingCapacity();
    }

    fn clientName(self: *const VanillaAdapter, value: []const u8) ?[]const u8 {
        for (self.clients) |client| if (std.mem.eql(u8, client.name, value)) return client.name;
        return null;
    }

    fn readStatus(self: *VanillaAdapter) !void {
        switch (try self.reader.interface.takeByte()) {
            0 => {},
            1 => {
                const message = try self.readStringAlloc(1024 * 1024);
                defer self.allocator.free(message);
                std.debug.print("Vanilla harness failure: {s}\n", .{message});
                return error.VanillaHarnessFailure;
            },
            else => return error.InvalidVanillaHarnessStatus,
        }
    }

    fn readCount(self: *VanillaAdapter, maximum: usize) !usize {
        const value = try self.reader.interface.takeInt(i32, .big);
        if (value < 0 or value > maximum) return error.InvalidVanillaHarnessCount;
        return @intCast(value);
    }

    fn readStringAlloc(self: *VanillaAdapter, maximum: usize) ![]u8 {
        const len = try self.readCount(maximum);
        const result = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(result);
        try self.reader.interface.readSliceAll(result);
        return result;
    }

    fn readPalette(self: *VanillaAdapter, maximum: usize) ![][]u8 {
        const count = try self.readCount(maximum);
        const result = try self.allocator.alloc([]u8, count);
        errdefer self.allocator.free(result);
        var initialized: usize = 0;
        errdefer for (result[0..initialized]) |entry| self.allocator.free(entry);
        while (initialized < count) : (initialized += 1) {
            result[initialized] = try self.readStringAlloc(64 * 1024);
        }
        return result;
    }

    fn readF64(self: *VanillaAdapter) !f64 {
        return @bitCast(try self.reader.interface.takeInt(u64, .big));
    }
};

fn freePalette(allocator: std.mem.Allocator, palette: [][]u8) void {
    for (palette) |entry| allocator.free(entry);
    allocator.free(palette);
}

fn fixtureIdentityAlias(definition: mcc.fixture.Definition, alias: []const u8) ?[]const u8 {
    for (definition.setup) |setup| switch (setup) {
        .spawn_entity => |entity| if (std.mem.eql(u8, entity.id, alias)) return entity.id,
        .spawn_item => |item| if (std.mem.eql(u8, item.id, alias)) return item.id,
        else => {},
    };
    return null;
}

fn writeCount(writer: *std.Io.Writer, value: usize) !void {
    if (value > std.math.maxInt(i32)) return error.VanillaHarnessValueTooLarge;
    try writer.writeInt(i32, @intCast(value), .big);
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try writeCount(writer, value.len);
    try writer.writeAll(value);
}

fn writeI16(writer: *std.Io.Writer, value: i16) !void {
    try writer.writeInt(i16, value, .big);
}

fn writeI32(writer: *std.Io.Writer, value: i32) !void {
    try writer.writeInt(i32, value, .big);
}

fn writeI64(writer: *std.Io.Writer, value: i64) !void {
    try writer.writeInt(i64, value, .big);
}

fn writeU64(writer: *std.Io.Writer, value: u64) !void {
    try writer.writeInt(u64, value, .big);
}

fn writeF32(writer: *std.Io.Writer, value: f32) !void {
    try writer.writeInt(u32, @bitCast(value), .big);
}

fn writeF64(writer: *std.Io.Writer, value: f64) !void {
    try writer.writeInt(u64, @bitCast(value), .big);
}
