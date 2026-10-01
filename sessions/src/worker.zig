const std = @import("std");
const network = @import("networking");
const engine = @import("engine.zig");
const session_protocol = @import("protocol.zig");
const session_protocol_input = @import("input.zig");
const Service = @import("service.zig").Service;
const Event = @import("service.zig").Event;

const assert = std.debug.assert;

const Trace = @import("metrics").Metrics(enum { pump, compression, fanout, networking });

pub const Route = @import("router.zig").Route;

/// One owner drives the Engine and all endpoints. Each endpoint has exactly one Simulation
/// producer. Different endpoints may run concurrently.
pub fn Worker(comptime Endpoint: type, comptime Hooks: type, comptime Router: type) type {
    if (!@hasDecl(Router, "route")) @compileError("Router must define route(self, profile)");
    return struct {
        const Self = @This();
        pub const Configuration = struct {
            connections: usize = 40,
            max_players: usize = 32,
            buffer_bytes: usize = 512 * 1024,
            protocols: *const Endpoint.Protocols,
            compression_threshold: ?usize = 256,
            metrics_cpu: bool = false,
            hooks: *Hooks,
            router: *Router,
            wakeup: ?*std.Io.Event = null,
        };

        const Engine = engine.Engine(Endpoint, Self);
        const Previous = struct {
            endpoint: *Service,
            handle: network.Handle,
        };

        const Binding = struct {
            endpoint: *Service,
            handle: network.Handle,
            native: network.Handle,
            configuring: bool = false,
            previous: ?Previous = null,
        };

        const SelectedRoute = struct {
            connection: network.Handle,
            destination: usize,
        };

        allocator: std.mem.Allocator,
        io: std.Io,
        config: Configuration,
        hooks: *Hooks,
        router: *Router,
        engine: *Engine,
        endpoints: []const *Service,
        bindings: []?Binding,
        selected_routes: []?SelectedRoute,
        compressed: []u8,
        workspaces: Endpoint.Workspaces,
        next_endpoint: usize = 0,
        stopping: std.atomic.Value(bool) = .init(false),
        reload_state: std.atomic.Value(enum(u8) { running, requested, parked }) = .init(.running),
        quiescing: bool = false,
        reload_removed: [Endpoint.versions.len]bool = @splat(false),
        metrics: Trace,
        encoded_packets: u64 = 0,
        encoded_bytes: u64 = 0,
        framed_bytes: u64 = 0,
        send_copy_bytes: u64 = 0,
        empty_preparations: u64 = 0,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: network.Transport, config: Configuration, endpoints: []const *Service) !*Self {
            if (endpoints.len == 0 or config.connections == 0 or config.connections > std.math.maxInt(u16) or config.max_players == 0 or config.max_players > config.connections)
                return error.InvalidConfiguration;

            var maximum: usize = 0;

            for (endpoints, 0..) |endpoint, i| {
                if (endpoint.owner != null) return error.InvalidConfiguration;
                if (endpoint.config.buffer_bytes != config.buffer_bytes) return error.InvalidConfiguration;

                for (endpoint.config.protocols) |selected| {
                    var found = false;

                    for (config.protocols.values) |protocol| found = found or protocol.number == selected.number;
                    if (!found) return error.InvalidConfiguration;
                }

                for (endpoints[0..i]) |previous| if (previous == endpoint) return error.InvalidConfiguration;
                maximum = @max(maximum, endpoint.framedBound(endpoint.config.page_bytes));
            }

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const bindings = try allocator.alloc(?Binding, config.connections);
            errdefer allocator.free(bindings);
            @memset(bindings, null);
            const selected_routes = try allocator.alloc(?SelectedRoute, config.connections);
            errdefer allocator.free(selected_routes);
            @memset(selected_routes, null);
            const compressed = try allocator.alloc(u8, maximum);
            errdefer allocator.free(compressed);
            self.* = .{
                .allocator = allocator,
                .io = io,
                .config = config,
                .hooks = config.hooks,
                .router = config.router,
                .engine = undefined,
                .endpoints = endpoints,
                .bindings = bindings,
                .selected_routes = selected_routes,
                .compressed = compressed,
                .workspaces = Endpoint.initWorkspaces(),
                .metrics = Trace.init(io, .{ .cpu = config.metrics_cpu }),
            };
            self.engine = try Engine.init(allocator, io, transport, .{
                .connections = config.connections,
                .max_players = config.max_players,
                .buffer_bytes = config.buffer_bytes,
                .max_packet = config.buffer_bytes - 3,
                .protocols = config.protocols,
                .compression_threshold = config.compression_threshold,
                .metrics_cpu = config.metrics_cpu,
                .observer = self,
            });

            for (endpoints) |endpoint| endpoint.owner = self;
            return self;
        }

        pub fn deinit(self: *Self) void {
            assert(self.drained());

            for (self.bindings) |binding| assert(binding == null);
            var reserve_failures: u64 = 0;
            var wait_ns: u64 = 0;

            for (self.endpoints) |endpoint| {
                reserve_failures += endpoint.reserve_failures;
                wait_ns += endpoint.producer_metrics.get(.output_wait).total_ns;
            }

            std.log.info("event=session_totals packets={d} raw_bytes={d} framed_bytes={d} compression_ns={d} reserve_failures={d}", .{ self.encoded_packets, self.encoded_bytes, self.framed_bytes, self.metrics.get(.compression).total_ns, reserve_failures });
            std.log.info("event=session_pipeline output_wait_ns={d} copy_ns={d} copy_bytes={d} empty_preparations={d} poll_ns={d} sent_bytes={d}", .{ wait_ns, self.metrics.get(.fanout).total_ns, self.send_copy_bytes, self.empty_preparations, self.engine.metrics.get(.poll).total_ns, self.engine.sent_bytes });
            self.metrics.log("sessions");
            self.engine.metrics.log("session_engine");
            self.engine.deinit();

            for (self.endpoints) |endpoint| endpoint.owner = null;
            self.allocator.free(self.compressed);
            self.allocator.free(self.selected_routes);
            self.allocator.free(self.bindings);
            self.allocator.destroy(self);
        }

        pub fn stop(self: *Self) void {
            self.stopping.store(true, .release);

            for (self.endpoints) |endpoint| endpoint.stop();
        }

        pub fn requestReload(self: *Self, removed: [Endpoint.versions.len]bool) void {
            assert(self.engine.networking.inheritance != null);
            assert(self.reload_state.load(.acquire) == .running);
            self.reload_removed = removed;
            assert(self.reload_state.swap(.requested, .acq_rel) == .running);
            self.engine.networking.notify(self.io);
        }

        /// Called with the Session thread joined and the old Simulation closed.
        pub fn restart(self: *Self) void {
            assert(self.reload_state.load(.acquire) == .parked);

            for (self.endpoints) |endpoint| {
                assert(endpoint.preparing.load(.acquire) == 0 and !endpoint.tick_active);
                assert(endpoint.event_read.load(.acquire) == endpoint.event_write.load(.acquire));

                for (endpoint.routes, endpoint.occupied, endpoint.credit) |*route, *occupied, *credit| {
                    route.* = null;
                    occupied.store(false, .release);
                    _ = credit.fetchAnd(~Service.active, .acq_rel);
                }
            }

            @memset(self.bindings, null);
            @memset(self.selected_routes, null);
            self.engine.restart();
            const native = self.engine.networking.inheritance.?;
            native.pause(native.context, self.io, false);
            self.quiescing = false;
            self.reload_state.store(.running, .release);
        }

        pub fn drained(self: *const Self) bool {
            for (self.endpoints) |endpoint| {
                if (endpoint.preparing.load(.acquire) != 0) return false;

                for (endpoint.moves) |*move| if (move.state.load(.acquire) != .idle) return false;
            }

            return self.engine.drained();
        }

        pub fn pump(self: *Self, timeout: ?std.Io.Timeout) !void {
            var pumping = self.metrics.begin(.pump);
            defer pumping.end();

            if (self.stopping.load(.acquire)) self.engine.beginShutdown();

            if (self.reload_state.load(.acquire) == .requested and !self.quiescing) {
                const native = self.engine.networking.inheritance.?;
                native.pause(native.context, self.io, true);
                self.quiescing = true;
                for (self.engine.connections) |connection| {
                    const handle = connection.handle orelse continue;
                    const selected = connection.protocol orelse continue;
                    inline for (Endpoint.versions, 0..) |Version, index| {
                        if (selected.number == Version.protocol_number and self.reload_removed[index]) {
                            std.log.info("event=reload_protocol_removed connection={d}:{d} protocol={d}", .{ handle.index, handle.generation, selected.number });
                            self.engine.disconnect(handle);
                        }
                    }
                }
            }

            for (self.bindings) |maybe_binding| {
                const binding = maybe_binding orelse continue;
                const endpoint = binding.endpoint;
                const index = binding.handle.index;
                const release = endpoint.releases[index].swap(0, .acq_rel);

                if (release != 0) {
                    assert(release == binding.handle.generation);
                    self.engine.releaseInput(binding.native);
                }

                const disconnect = endpoint.disconnects[index].swap(0, .acq_rel);

                if (disconnect == binding.handle.generation or endpoint.stopping.load(.acquire)) self.engine.disconnect(binding.native);
            }

            for (self.endpoints) |source| for (source.moves, 0..) |*move, index| {
                if (move.state.load(.acquire) != .committed) continue;

                const target = move.destination;
                const credit = source.credit[index].load(.acquire);
                if (credit >> 32 != move.generation or credit & Service.active == 0 or source.stopping.load(.acquire) or target.stopping.load(.acquire)) {
                    const held = target.occupied[move.slot].swap(false, .release);
                    assert(held);
                    move.state.store(.idle, .release);
                    continue;
                }

                const consumed = source.output.ready.head.load(.acquire);
                if (consumed -% move.boundary > std.math.maxInt(usize) / 2 or credit & (Service.active - 1) != source.config.buffer_bytes) continue;
                if (source.event_write.load(.monotonic) -% source.event_read.load(.acquire) == source.events.len) continue;

                const native = source.routes[index].?;
                const generation = (target.credit[move.slot].load(.acquire) >> 32) + 1;
                if (generation > std.math.maxInt(u32)) {
                    const held = target.occupied[move.slot].swap(false, .release);
                    assert(held);
                    move.state.store(.idle, .release);
                    continue;
                }

                if (!try self.engine.reconfigure(native)) continue;

                const connection = &self.engine.connections[native.index];
                const protocol_number = connection.protocol.?.number;

                for (target.config.protocols) |*protocol| {
                    if (protocol.number == protocol_number) {
                        connection.protocol = protocol;
                        break;
                    }
                }

                const old: network.Handle = .{ .index = @intCast(index), .generation = move.generation };
                const next: network.Handle = .{ .index = move.slot, .generation = @intCast(generation) };
                _ = source.credit[index].fetchAnd(~Service.active, .acq_rel);
                source.routes[index] = null;
                target.routes[move.slot] = native;
                target.credit[move.slot].store(generation << 32, .release);
                self.bindings[native.index] = .{
                    .endpoint = target,
                    .handle = next,
                    .native = native,
                    .configuring = true,
                    .previous = .{ .endpoint = source, .handle = old },
                };
                move.state.store(.idle, .release);
                const announced = source.push(.{ .left = old });
                assert(announced);
                const held = source.occupied[index].swap(false, .release);
                assert(held);
                std.log.info("event=session_transfer connection={d}:{d} source={d}:{d} destination={d}:{d}", .{ native.index, native.generation, old.index, old.generation, next.index, next.generation });
            };

            var batch_bytes: usize = 0;
            var batch_packets: usize = 0;
            var empty: usize = 0;

            while (batch_bytes < 1024 * 1024 and batch_packets < 64 and empty < self.endpoints.len) {
                const endpoint = self.endpoints[self.next_endpoint];
                self.next_endpoint = (self.next_endpoint + 1) % self.endpoints.len;
                const packet = endpoint.output.takeReady() orelse {
                    empty += 1;
                    continue;
                };
                empty = 0;
                defer {
                    const released = endpoint.output.releaseReady(packet.page, packet.generation);
                    assert(released);
                    const previous = endpoint.preparing.fetchSub(1, .release);
                    assert(previous > 0);
                    endpoint.output_progress.set(self.io);

                    if (self.config.wakeup) |wakeup| wakeup.set(self.io);
                }
                const charge = endpoint.framedBound(packet.bytes.len);
                for (self.config.protocols.values) |selected| {
                    for ([_]bool{ false, true }) |compression_enabled| {
                        var recipients: usize = 0;
                        for (packet.recipients) |handle| {
                            const credit = endpoint.credit[handle.index].load(.acquire);
                            if (credit >> 32 != handle.generation or credit & Service.active == 0) continue;
                            const native = endpoint.routes[handle.index] orelse unreachable;
                            const connection = &self.engine.connections[native.index];
                            recipients += @intFromBool(connection.protocol.?.number == selected.number and Endpoint.compressed(&connection.lifecycle.?) == compression_enabled);
                        }
                        if (recipients == 0) continue;

                        const bytes = blk: {
                            var timing = pumping.begin(.compression);
                            defer timing.end();
                            timing.add(.bytes, packet.bytes.len);
                            timing.add(.records, 1);
                            break :blk try Endpoint.sharedFrame(selected.number, &self.workspaces, endpoint.output.framingStorage(packet), packet.bytes.len, if (compression_enabled) self.config.compression_threshold else null, self.compressed);
                        };
                        assert(bytes.len <= charge);
                        var fanout = pumping.begin(.fanout);
                        defer fanout.end();

                        for (packet.recipients) |handle| {
                            const credit = endpoint.credit[handle.index].load(.acquire);
                            if (credit >> 32 != handle.generation or credit & Service.active == 0) continue;
                            const native = endpoint.routes[handle.index] orelse unreachable;
                            const connection = &self.engine.connections[native.index];
                            if (connection.protocol.?.number != selected.number or Endpoint.compressed(&connection.lifecycle.?) != compression_enabled) continue;
                            self.engine.sendFramed(native, bytes) catch |err| switch (err) {
                                error.Closed => {
                                    endpoint.refund(handle, charge);
                                    continue;
                                },
                                else => return err,
                            };
                            endpoint.refund(handle, charge - bytes.len);
                            self.send_copy_bytes += bytes.len;
                            fanout.add(.bytes, bytes.len);
                        }
                        self.encoded_packets += 1;
                        self.encoded_bytes += packet.bytes.len;
                        self.framed_bytes += bytes.len;
                        batch_bytes += packet.bytes.len;
                    }
                }
                batch_packets += 1;
            }

            self.empty_preparations += @intFromBool(batch_packets == 0);
            const networking = pumping.begin(.networking);
            defer networking.end();
            _ = try self.engine.pump(if (batch_bytes >= 1024 * 1024 or batch_packets == 64) .{ .duration = .{ .clock = .awake, .raw = .zero } } else timeout);

            if (self.quiescing) {
                var empty_output = true;

                for (self.endpoints) |endpoint| empty_output = empty_output and endpoint.preparing.load(.acquire) == 0;

                if (empty_output) {
                    const parked = try self.engine.park();
                    const native = self.engine.networking.inheritance.?;

                    if (parked and native.ready(native.context)) self.reload_state.store(.parked, .release);
                }
            }
        }

        pub fn attached(self: *Self, profile: engine.Profile) bool {
            if (self.bindings[profile.connection.index]) |*binding| {
                assert(binding.configuring and std.meta.eql(binding.native, profile.connection));
                const previous = binding.previous.?;
                if (previous.endpoint.departed[previous.handle.index].load(.acquire) < previous.handle.generation) return false;

                const endpoint = binding.endpoint;
                var event: Event = .{ .joined = .{
                    .handle = binding.handle,
                    .protocol = profile.protocol,
                    .uuid = profile.uuid,
                    .name = undefined,
                    .name_len = @intCast(profile.name.len),
                    .cause = .transfer,
                } };
                @memcpy(event.joined.name[0..profile.name.len], profile.name);
                endpoint.credit[binding.handle.index].store((@as(u64, binding.handle.generation) << 32) | Service.active | endpoint.config.buffer_bytes, .release);
                if (!endpoint.push(event)) {
                    _ = endpoint.credit[binding.handle.index].fetchAnd(~Service.active, .acq_rel);
                    return false;
                }

                binding.configuring = false;
                binding.previous = null;
                return true;
            }

            assert(self.bindings[profile.connection.index] == null);
            const decision = self.select(profile);
            const selected = switch (decision) {
                .destination => |index| index,
                .pending => return false,
                .reject => {
                    self.engine.disconnect(profile.connection);
                    return false;
                },
            };
            if (selected >= self.endpoints.len) {
                self.engine.disconnect(profile.connection);
                return false;
            }
            const endpoint = self.endpoints[selected];
            if (endpoint.stopping.load(.acquire)) return false;

            var supported = false;

            for (endpoint.config.protocols) |protocol| supported = supported or protocol.number == profile.protocol;
            if (!supported) {
                self.engine.disconnect(profile.connection);
                return false;
            }

            for (endpoint.routes, 0..) |*route, index| {
                if (endpoint.occupied[index].cmpxchgStrong(false, true, .acq_rel, .acquire) != null) continue;
                assert(route.* == null);
                const generation = (endpoint.credit[index].load(.acquire) >> 32) + 1;
                if (generation > std.math.maxInt(u32)) {
                    endpoint.occupied[index].store(false, .release);
                    continue;
                }

                const handle: network.Handle = .{ .index = @intCast(index), .generation = @intCast(generation) };
                var event: Event = .{ .joined = .{
                    .handle = handle,
                    .protocol = profile.protocol,
                    .uuid = profile.uuid,
                    .name = undefined,
                    .name_len = @intCast(profile.name.len),
                } };

                if (self.engine.connections[profile.connection.index].resumed) event.joined.cause = .reload;
                @memcpy(event.joined.name[0..profile.name.len], profile.name);
                route.* = profile.connection;
                self.bindings[profile.connection.index] = .{ .endpoint = endpoint, .handle = handle, .native = profile.connection };
                endpoint.credit[index].store((generation << 32) | Service.active | endpoint.config.buffer_bytes, .release);
                if (endpoint.push(event)) {
                    std.log.info("event=session_routed endpoint={d} local={d}:{d} connection={d}:{d}", .{ selected, handle.index, handle.generation, profile.connection.index, profile.connection.generation });
                    return true;
                }

                endpoint.credit[index].store(generation << 32, .release);
                route.* = null;
                endpoint.occupied[index].store(false, .release);
                self.bindings[profile.connection.index] = null;
                return false;
            }

            return false;
        }

        pub fn input(self: *Self, handle: network.Handle, protocol: i32, bytes: []const u8) engine.Disposition {
            if (self.reload_state.load(.acquire) != .running) return .consumed;

            const binding = self.bindings[handle.index].?;
            assert(std.meta.eql(binding.native, handle));
            if (binding.endpoint.moves[binding.handle.index].state.load(.acquire) == .committed) return .consumed;
            return if (binding.endpoint.push(.{ .input = .{ .handle = binding.handle, .protocol = protocol, .bytes = bytes } })) .borrowed else .blocked;
        }

        pub fn status(self: *Self, protocol: i32, packet: []const u8, output: []u8) !?[]const u8 {
            const request: session_protocol.StatusRequest = .{
                .protocol = protocol,
                .online_players = self.engine.admitted,
                .maximum_players = self.config.max_players,
            };
            return self.hooks.statusPacket(request, packet, output);
        }

        pub fn handshake(self: *Self, packet: []const u8) !session_protocol.Handshake {
            return self.hooks.handshake(packet);
        }

        pub fn sessionInput(self: *Self, comptime phase_kind: session_protocol_input.Phase, profile: session_protocol.Profile, io: std.Io, now: i96, packet: []const u8, output: []u8) !session_protocol_input.Effect(phase_kind) {
            return self.hooks.input(phase_kind, .{ .profile = profile, .io = io, .now = now }, packet, output);
        }

        pub fn play(self: *Self, profile: session_protocol.Profile, event: session_protocol.PlayEvent, output: []u8) !?[]const u8 {
            return self.hooks.play(Endpoint.versions, profile, event, output);
        }

        pub fn select(self: *Self, profile: engine.Profile) Route {
            if (self.selected_routes[profile.connection.index]) |selected|
                if (std.meta.eql(selected.connection, profile.connection))
                    return .{ .destination = selected.destination };

            const decision = self.router.route(profile);
            if (decision == .destination) {
                if (decision.destination >= self.endpoints.len) return .reject;
                const endpoint = self.endpoints[decision.destination];
                var supported = false;
                for (endpoint.config.protocols) |protocol| supported = supported or protocol.number == profile.protocol;
                if (!supported) return .reject;
                self.selected_routes[profile.connection.index] = .{
                    .connection = profile.connection,
                    .destination = decision.destination,
                };
            }
            return decision;
        }

        pub fn login(self: *Self, handle: network.Handle, state: *session_protocol.State, number: i32, event: session_protocol.PhaseEvent, output: []u8) !session_protocol.LoginStep {
            const scope: session_protocol.PhaseScope = .{
                .profile = .{ .connection = handle, .protocol = number, .uuid = state.uuid, .name = state.name[0..state.name_len] },
                .destination = null,
                .identity = &state.uuid,
                .io = self.io,
                .compression_threshold = self.config.compression_threshold,
            };
            inline for (Endpoint.versions) |Version| {
                if (number == Version.protocol_number)
                    return self.hooks.phase(.login, scope, event, output);
            }
            return error.UnsupportedProtocol;
        }

        pub fn configuration(self: *Self, handle: network.Handle, state: *session_protocol.State, number: i32, event: session_protocol.PhaseEvent, output: []u8) !session_protocol.ConfigurationStep {
            var destination: ?usize = null;
            if (self.bindings[handle.index]) |binding| {
                for (self.endpoints, 0..) |endpoint, index| if (endpoint == binding.endpoint) {
                    destination = index;
                    break;
                };
            } else if (self.selected_routes[handle.index]) |selected| {
                if (std.meta.eql(selected.connection, handle)) destination = selected.destination;
            }
            const scope: session_protocol.PhaseScope = .{
                .profile = .{ .connection = handle, .protocol = number, .uuid = state.uuid, .name = state.name[0..state.name_len] },
                .destination = destination,
                .io = self.io,
            };
            inline for (Endpoint.versions) |Version| {
                if (number == Version.protocol_number)
                    return self.hooks.phase(.configuration, scope, event, output);
            }
            return error.UnsupportedProtocol;
        }

        pub fn detached(self: *Self, handle: network.Handle) bool {
            const binding = self.bindings[handle.index].?;
            assert(std.meta.eql(binding.native, handle));
            _ = binding.endpoint.credit[binding.handle.index].fetchAnd(~Service.active, .acq_rel);
            if (!binding.configuring and !binding.endpoint.push(.{ .left = binding.handle })) return false;
            binding.endpoint.routes[binding.handle.index] = null;
            self.bindings[handle.index] = null;
            const held = binding.endpoint.occupied[binding.handle.index].swap(false, .release);
            assert(held);
            return true;
        }

        pub fn closed(self: *Self, handle: network.Handle) void {
            if (self.selected_routes[handle.index]) |selected| {
                if (std.meta.eql(selected.connection, handle)) self.selected_routes[handle.index] = null;
            }
            self.hooks.closed(handle);
        }

        pub fn sent(self: *Self, handle: network.Handle, bytes: usize) void {
            const binding = self.bindings[handle.index].?;
            assert(std.meta.eql(binding.native, handle));
            binding.endpoint.refund(binding.handle, bytes);
            binding.endpoint.output_progress.set(self.io);

            if (self.config.wakeup) |wakeup| wakeup.set(self.io);
        }
    };
}
