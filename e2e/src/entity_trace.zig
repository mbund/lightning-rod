//! The server's half of the client traces: each item's and arrow's exact state after every tick,
//! for `entity_compare` to hold what the clients computed to. Ticks after replication, so it
//! writes what each tick sent from.
const std = @import("std");
const entities = @import("entities");
const vanilla = @import("vanilla");
const lightning_rod = @import("lightning_rod");

pub const EntityTrace = struct {
    pub const id = "e2e:entity_trace";
    pub const Configuration = struct {
        /// Where the trace goes, as `server.entities`: the scenario's artifacts.
        directory: ?[]const u8 = null,
    };
    pub const Dependencies = struct {
        entities: *entities.Entities,
        dropped: *vanilla.ItemEntities,
        projectiles: *vanilla.Projectiles,
        item_replication: *vanilla.ItemReplication,
        projectile_replication: *vanilla.ProjectileReplication,
    };

    deps: Dependencies,
    io: std.Io,
    file: ?std.Io.File,
    writer: std.Io.File.Writer,
    buffer: []u8,
    /// With client models: each item as its model has it, as `server.model.entities`.
    model_file: ?std.Io.File = null,
    model_writer: std.Io.File.Writer = undefined,
    model_buffer: []u8,
    ticks: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*EntityTrace {
        const self = try allocator.create(EntityTrace);
        const buffer = try allocator.alloc(u8, 64 * 1024);
        const model_buffer = try allocator.alloc(u8, 64 * 1024);
        var model_file: ?std.Io.File = null;
        const file: ?std.Io.File = if (config.directory) |directory| file: {
            var opened = try std.Io.Dir.cwd().openDir(io, directory, .{});
            defer opened.close(io);
            if (deps.item_replication.sync.models != null) model_file = try opened.createFile(io, "server.model.entities", .{});
            break :file try opened.createFile(io, "server.entities", .{});
        } else null;
        self.* = .{ .deps = deps, .io = io, .file = file, .writer = if (file) |value| value.writer(io, buffer) else undefined, .buffer = buffer, .model_file = model_file, .model_buffer = model_buffer };
        if (model_file) |value| self.model_writer = value.writer(io, model_buffer);
        return self;
    }

    pub fn tick(self: *EntityTrace) !void {
        if (self.file == null) return;
        self.ticks += 1;
        const out = &self.writer.interface;
        var rows = self.deps.dropped.rows();
        while (try rows.next()) |row| {
            const view = (try self.deps.dropped.read(row.id)) orelse continue;
            if (!view.metadata.alive) continue;
            try write(out, self.ticks, self.deps.dropped.networkId(row.id), view.body.position, view.body.velocity, view.metadata.on_ground);
            if (self.model_file != null) {
                const model = self.modelOf(row.id) orelse Shown{ .position = view.body.position, .velocity = view.body.velocity, .on_ground = view.metadata.on_ground };
                try write(&self.model_writer.interface, self.ticks, self.deps.dropped.networkId(row.id), model.position, model.velocity, model.on_ground);
            }
        }
        const directory = &self.deps.entities.directory;
        for (0..directory.high()) |index| {
            const slot: u32 = @intCast(index);
            if (!self.deps.projectiles.holds(slot)) continue;
            const shown = (try self.deps.projectiles.shown(slot)) orelse continue;
            // What replication sends as on the ground: whether it is stuck in a block.
            try write(out, self.ticks, entities.Entities.networkOfSlot(slot), shown.position, shown.velocity, shown.in_ground);
        }
        // An e2e server may be stopped without closing: what each tick wrote is kept.
        try out.flush();
        if (self.model_file != null) try self.model_writer.interface.flush();
    }

    pub fn close(self: *EntityTrace, io: std.Io, _: *lightning_rod.Closing) void {
        const file = self.file orelse return;
        self.writer.interface.flush() catch {};
        file.close(io);
        self.file = null;
        if (self.model_file) |model| {
            self.model_writer.interface.flush() catch {};
            model.close(io);
            self.model_file = null;
        }
    }

    const Shown = struct { position: [3]f64, velocity: [3]f64, on_ground: bool };

    /// An item as the traced client's class has it, where replication predicts items: the first
    /// viewer's, as a proof has one client.
    fn modelOf(self: *const EntityTrace, entity: entities.Id) ?Shown {
        const prediction = &(self.deps.item_replication.sync.models orelse return null);
        const slot = self.deps.entities.directory.slotOf(entity) orelse return null;
        var viewers = prediction.deps.tracking.known(slot).iterator();
        const player = viewers.next() orelse return null;
        const model = prediction.lastModelOf(slot, entity, prediction.classOf(slot, player)) orelse return null;
        return .{ .position = model.position, .velocity = model.velocity, .on_ground = model.on_ground };
    }

    fn write(out: *std.Io.Writer, at: u64, network_id: i32, position: [3]f64, velocity: [3]f64, on_ground: bool) !void {
        try out.print("{d} {d}", .{ at, network_id });
        for (position ++ velocity) |value| try out.print(" {x}", .{@as(u64, @bitCast(value))});
        try out.print(" {d}\n", .{@intFromBool(on_ground)});
    }
};
