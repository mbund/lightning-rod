const std = @import("std");
const builtin = @import("builtin");
const lightning_rod = @import("lightning_rod");
const metrics = @import("metrics");
const reload = @import("reload");
const sessions = @import("sessions.zig");
const handoff = @import("handoff.zig");
const Transport = @import("transport.zig").Transport;
const Runtime = @import("plugins.zig").Runtime;

const Routing = @import("plugin.zig").Routing;
fn EndpointOptions(comptime T: type) type {
    return struct {
        id: T,
        connections: usize = 32,
        page_bytes: usize = 384 * 1024,
        output: ?**sessions.Service = null,
    };
}

pub fn Core(comptime Endpoint: type, comptime Plugins: type, comptime Router: type) type {
    return struct {
        const Self = @This();
        const Hooks = Runtime(Endpoint, Plugins);
        const Worker = sessions.Worker(Endpoint, Hooks, Router);
        pub const EndpointConfiguration = EndpointOptions(Router.Destination);
        pub const id = "lightning_rod:sessions";
        pub const Configuration = struct {
            plugins: Plugins,
            protocols: *Endpoint.Protocols,
            router: Router,
            address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 25565 } },
            /// Transfers the listening socket to this instance. Resume uses the handoff socket.
            inherited_listener: ?i32 = null,
            max_players: usize = 32,
            compression_threshold: ?usize = 256,
            /// Per-player output credit and maximum input buffer capacity.
            buffer_bytes: usize = 512 * 1024,
            /// Resident capacity for each input, output, and control buffer.
            connection_bytes: usize = 8 * 1024,
            input_burst_slots: usize = 8,
            output_burst_slots: usize = 8,
            configuration_slots: usize = 8,
            decode_slots: usize = 8,
            framing_slots: usize = 8,
            max_pending_wire_bytes: usize = 1024 * 1024,
            endpoints: []const EndpointConfiguration,
            output_pages: usize = 32,
            plugin_memory_bytes: usize = 64 * 1024,
            metrics: metrics.Registry.Configuration = .{},
        };
        pub const Options = struct { memory: *lightning_rod.Memory, metrics: *metrics.Registry, handoff: ?*lightning_rod.Resume = null };

        const Previous = struct { endpoint: *sessions.Service, handle: sessions.Handle };
        previous: []Previous,
        allocator: std.mem.Allocator,
        transport: Transport,
        hooks: *Hooks,
        router: Router,
        worker: *Worker,
        output_pool: sessions.OutputPool,
        routing: Routing,
        config: Configuration,
        registry: metrics.Registry,
        owned_buffers: metrics.Gauge = .{},
        owned_bytes: usize = 0,
        reload_plan: [Endpoint.versions.len]bool = @splat(false),
        reload_intent: std.atomic.Value(bool) = .init(false),

        pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, options: Options) !*Self {
            if (config.max_players == 0 or config.max_players > std.math.maxInt(usize) - 8 or config.endpoints.len == 0) return error.InvalidSessionCapacity;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const owned = options.memory.allocator(id);
            self.* = .{ .previous = try owned.alloc(Previous, config.max_players + 8), .allocator = owned, .transport = undefined, .hooks = undefined, .router = config.router, .worker = undefined, .output_pool = undefined, .routing = undefined, .config = config, .registry = try metrics.Registry.init(owned, io, config.metrics) };
            errdefer self.registry.deinit();
            try self.registry.attach(options.metrics);
            var maximum_packet: usize = 0;
            var maximum_recipients: usize = 0;
            for (config.endpoints) |endpoint| {
                maximum_packet = @max(maximum_packet, endpoint.page_bytes);
                maximum_recipients = @max(maximum_recipients, endpoint.connections);
            }
            self.output_pool = try sessions.OutputPool.init(owned, .{ .pages = config.output_pages, .page_bytes = maximum_packet, .recipients_per_page = maximum_recipients });
            errdefer self.output_pool.deinit();
            var inherited: ?i32 = null;
            errdefer if (inherited) |descriptor| {
                const file: std.Io.File = .{ .handle = descriptor, .flags = .{ .nonblocking = false } };
                file.close(io);
            };
            var compression = config.compression_threshold;
            if (options.handoff) |incoming| {
                const header = try handoff.Header.read(incoming.reader);
                try cloexec(header.listener);
                inherited = header.listener;
                compression = header.compression_threshold;
            } else if (config.inherited_listener) |listener| {
                if (listener < 3) return error.InvalidDescriptor;
                try cloexec(listener);
                inherited = listener;
            }
            self.transport = try Transport.init(owned, io, .{ .address = config.address, .connections = config.max_players + 8, .inherited_listener = inherited });
            inherited = null;
            errdefer self.transport.deinit(io);
            const endpoints = try owned.alloc(*sessions.Service, config.endpoints.len);
            errdefer owned.free(endpoints);
            const destinations = try owned.alloc(Router.Destination, config.endpoints.len);
            defer owned.free(destinations);
            for (config.endpoints, destinations) |endpoint, *destination| destination.* = endpoint.id;
            var initialized: usize = 0;
            errdefer for (endpoints[0..initialized]) |endpoint| endpoint.deinit();
            for (config.endpoints, endpoints) |endpoint_config, *endpoint| {
                endpoint.* = try sessions.Service.init(owned, io, self.transport.transport(), .{
                    .connections = endpoint_config.connections,
                    .buffer_bytes = config.buffer_bytes,
                    .metrics = options.metrics,
                    .protocols = &config.protocols.values,
                    .pages = config.output_pages,
                    .output_pool = &self.output_pool,
                    .page_bytes = endpoint_config.page_bytes,
                });
                initialized += 1;
            }
            self.routing = .{ .endpoints = endpoints };
            self.hooks = try Hooks.init(owned, io, config.plugins, .{ .sessions = endpoints[0], .endpoints = endpoints, .metrics = &self.registry }, config.plugin_memory_bytes, config.max_players + 8);
            errdefer self.hooks.deinit(io);
            self.worker = try Worker.init(owned, self.transport.transport(), .{
                .connections = config.max_players + 8,
                .max_players = config.max_players,
                .buffer_bytes = config.buffer_bytes,
                .connection_bytes = config.connection_bytes,
                .input_burst_slots = config.input_burst_slots,
                .output_burst_slots = config.output_burst_slots,
                .configuration_slots = config.configuration_slots,
                .decode_slots = config.decode_slots,
                .framing_slots = config.framing_slots,
                .max_pending_wire_bytes = config.max_pending_wire_bytes,
                .protocols = config.protocols,
                .hooks = self.hooks,
                .router = &self.router,
                .destinations = destinations,
                .compression_threshold = compression,
                .metrics = &self.registry,
            }, endpoints);
            errdefer self.worker.deinitUnstarted();
            if (options.handoff) |incoming| {
                try self.worker.engine.readResume(io, incoming.reader, incoming.file_reader);
                try self.worker.restorePlayers(io);
            }
            const allocated = try options.metrics.gauge(.{ .namespace = id, .name = "owned_buffers", .description = "Preallocated endpoint, engine, codec, and protocol plugin buffers", .unit = .bytes });
            var buffer_bytes = self.hooks.memoryBytes() + self.output_pool.memoryBytes();
            for (endpoints) |endpoint| buffer_bytes += endpoint.memoryBytes();
            for (self.worker.frames) |frame| buffer_bytes += frame.bytes.len;
            const engine = self.worker.engine;
            buffer_bytes += engine.input.len + engine.output.len + engine.decoded.memoryBytes() + engine.input_bursts.memoryBytes() + engine.output_bursts.memoryBytes() + engine.configurations.memoryBytes() + engine.control_raw.memoryBytes() + engine.scratch.len + engine.control_storage.len;
            buffer_bytes += engine.control_jobs.len * @sizeOf(@TypeOf(engine.control_jobs[0]));
            allocated.set(buffer_bytes);
            self.owned_buffers = allocated;
            self.owned_bytes = buffer_bytes;
            self.registry.seal();
            for (config.endpoints, endpoints) |endpoint_config, endpoint| {
                if (endpoint_config.output) |output| output.* = endpoint;
            }
            return self;
        }
        pub fn run(self: *Self, io: std.Io) !void {
            errdefer self.transport.pause(io, true);
            try self.worker.run(io);
            self.transport.pause(io, true);
            if (self.worker.stopping.load(.acquire)) self.hooks.close(io);
        }
        pub fn quiesce(self: *Self, io: std.Io) void {
            if (self.reload_intent.load(.acquire)) {
                if (self.worker.reload_state.load(.acquire) == .running) self.worker.requestReload(io, self.reload_plan);
            } else self.worker.stop();
            self.transport.notify(io);
        }
        pub fn abort(self: *Self, io: std.Io) void {
            self.transport.abort();
            self.hooks.close(io);
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            if (self.transport.aborted) self.worker.abort(io);
            if (self.worker.started) self.worker.deinit() else self.worker.deinitUnstarted();
            self.hooks.deinit(io);
            for (self.routing.endpoints) |endpoint| endpoint.deinit();
            self.output_pool.deinit();
            self.transport.deinit(io);
            self.allocator.free(self.routing.endpoints);
            self.allocator.free(self.previous);
            self.registry.deinit();
        }
        pub fn retainReload(comptime Backend: type) void {
            Backend.retainManifest(Endpoint);
        }
        pub fn prepareReload(self: *Self, _: std.Io, image: reload.Compatibility) !void {
            var removed: [Endpoint.versions.len]bool = undefined;
            inline for (Endpoint.versions, 0..) |Version, index| removed[index] = !image.supports(Version.protocol_number, null);
            self.reload_plan = removed;
            self.reload_intent.store(true, .release);
        }
        pub fn writeReload(self: *Self, io: std.Io, image: reload.Compatibility, writer: *std.Io.Writer, descriptors: []i32) !usize {
            self.worker.discardInputs();
            if (self.worker.reload_state.load(.acquire) != .parked) {
                // Before the first network turn there are no socket loans.
                if (!self.worker.engine.drained()) return error.ReloadNotQuiesced;
                self.transport.pause(io, true);
                self.worker.engine.reloading = true;
                self.worker.reload_state.store(.parked, .release);
            }
            var count: usize = 1;
            if (descriptors.len == 0) return error.ResumeCapacity;
            descriptors[0] = self.transport.listenerDescriptor();
            for (self.worker.engine.connections) |connection| if (connection.handle) |handle| {
                if (connection.protocol) |protocol| if (!image.supports(protocol.number, Endpoint.resumeFormat(&connection.lifecycle.?))) return error.ReloadProtocolUnsupported;
                if (count == descriptors.len) return error.ResumeCapacity;
                descriptors[count] = self.transport.descriptor(handle);
                count += 1;
            };
            const header: handoff.Header = .{ .listener = descriptors[0], .compression_threshold = self.worker.config.compression_threshold };
            try header.write(writer);
            try self.worker.engine.writeResume(writer);
            return count;
        }
        pub fn resumeReload(self: *Self, io: std.Io) !void {
            self.reload_intent.store(false, .release);
            const previous = self.previous;
            var count: usize = 0;
            for (self.worker.bindings) |binding| if (binding) |value| {
                previous[count] = .{ .endpoint = value.endpoint, .handle = value.handle };
                count += 1;
            };
            self.worker.restart(io);
            for (previous[0..count]) |value| if (!value.endpoint.push(.{ .left = value.handle })) return error.ResumeCapacity;
            try self.worker.restorePlayers(io);
        }
    };
}
fn cloexec(fd: i32) !void {
    if (builtin.os.tag != .linux) return;
    const result = std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(usize, std.posix.FD_CLOEXEC));
    if (std.posix.errno(result) != .SUCCESS) return error.InvalidDescriptor;
}
