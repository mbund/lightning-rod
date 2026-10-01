const std = @import("std");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");

const plugin = lightning_rod.plugin;
const PhaseKind = enum { login, configuration };

pub fn Runtime(comptime Endpoint: type, comptime Selections: type) type {
    plugin.validate(Selections);
    const count = plugin.selectedCount(Selections);
    const states = comptime phaseStateTypes(Selections);

    return struct {
        const Self = @This();
        const ConnectionPhaseState = struct {
            generation: u32 = 0,
            phase: PhaseKind = .login,
            active: bool = false,
            index: usize = 0,
            play_index: usize = 0,
            values: std.meta.Tuple(&states) = undefined,
        };

        memory: []u8,
        allocator: std.mem.Allocator,
        io: std.Io,
        fixed: std.heap.FixedBufferAllocator,
        instances: plugin.Instances(Selections) = .{},
        inputs: sessions.Inputs(Endpoint.versions) = undefined,
        phases: sessions.Phases = undefined,
        connections: []ConnectionPhaseState = undefined,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, selections: Selections, environment: anytype, memory_bytes: usize, connection_count: usize) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const memory = try allocator.alloc(u8, memory_bytes);
            errdefer allocator.free(memory);
            self.* = .{ .memory = memory, .allocator = allocator, .io = io, .fixed = std.heap.FixedBufferAllocator.init(memory) };
            errdefer self.closeInitialized();
            self.connections = try self.fixed.allocator().alloc(ConnectionPhaseState, connection_count);
            @memset(self.connections, .{});
            self.inputs.init();
            self.phases = try sessions.Phases.init(self.fixed.allocator(), count);
            const environment_with_input = plugin.environment(environment, .{ .input = &self.inputs, .handshake = &self.inputs.handshake, .phases = &self.phases });

            inline for (0..count) |index| {
                const Plugin = plugin.selectedPlugin(plugin.selectedType(Selections, index));
                self.phases.owner = index;
                inline for (Endpoint.versions, 0..) |_, version_index| {
                    self.inputs.login.tables[version_index].owner = index;
                    self.inputs.configuration.tables[version_index].owner = index;
                    self.inputs.play.tables[version_index].owner = index;
                }
                const deps = if (@hasDecl(Plugin, "Dependencies")) self.dependencies(Plugin.Dependencies, environment_with_input, index) else .{};
                const meta = if (@hasField(@TypeOf(environment), "meta")) environment.meta else .{};
                self.instances.pointers[index] = try plugin.initialize(Plugin, self.fixed.allocator(), io, selections[index].configuration, deps, meta);
                if (@sizeOf(Plugin) != 0) {
                    const address = @intFromPtr(self.instances.pointers[index]);
                    if (address < @intFromPtr(memory.ptr) or address + @sizeOf(Plugin) > @intFromPtr(memory.ptr) + memory.len)
                        return error.SessionPluginAllocationInvalid;
                }
                self.instances.initialized += 1;
            }
            self.inputs.seal();
            self.phases.sealed = true;
            if (self.inputs.handshake.call == null) return error.MissingHandshakeHandler;
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.connections) |connection| std.debug.assert(connection.generation == 0);
            self.closeInitialized();
            self.allocator.free(self.memory);
            const allocator = self.allocator;
            self.* = undefined;
            allocator.destroy(self);
        }

        fn closeInitialized(self: *Self) void {
            var slots: [plugin.closeTokenCount(Selections)]std.atomic.Value(bool) = undefined;
            var closing = lightning_rod.Closing.init(self.io, .{
                .clock = .awake,
                .raw = .{ .nanoseconds = std.Io.Clock.now(.awake, self.io).nanoseconds + 5 * std.time.ns_per_s },
            }, &slots);
            inline for (0..count) |offset| {
                const index = count - offset - 1;
                const Plugin = plugin.selectedPlugin(plugin.selectedType(Selections, index));
                if (index < self.instances.initialized)
                    plugin.close(Plugin, self.instances.get(Plugin), self.io, &closing);
            }
            closing.seal();
            closing.wait() catch |err| std.debug.panic("Sessions plugin shutdown failed: {s}", .{@errorName(err)});
            self.instances.initialized = 0;
        }

        pub fn handshake(self: *Self, packet: []const u8) !sessions.protocol.Handshake {
            return self.inputs.handshake.dispatch(packet);
        }

        pub fn statusPacket(self: *Self, request: sessions.StatusRequest, packet: []const u8, output: []u8) !?[]const u8 {
            inline for (Endpoint.versions, 0..) |Version, index|
                if (request.protocol == Version.protocol_number)
                    return self.inputs.status.tables[index].dispatch(request, packet, output);
            return error.UnsupportedProtocol;
        }

        pub fn input(self: *Self, comptime phase_kind: sessions.InputPhase, scope: sessions.InputScope, packet: []const u8, output: []u8) !sessions.InputEffect(phase_kind) {
            const handle = scope.profile.connection;
            if (handle.index >= self.connections.len or handle.generation == 0) return error.InvalidConnection;
            const connection = &self.connections[handle.index];
            if (connection.generation != handle.generation) {
                connection.* = .{ .generation = handle.generation };
                inline for (0..count) |index| connection.values[index] = .{};
            }

            inline for (Endpoint.versions, 0..) |Version, version_index| {
                if (scope.profile.protocol == Version.protocol_number) {
                    const input_set = switch (phase_kind) {
                        .login => &self.inputs.login.tables[version_index],
                        .configuration => &self.inputs.configuration.tables[version_index],
                        .play => &self.inputs.play.tables[version_index],
                    };
                    const entry, const header = (try input_set.entry(packet)) orelse return .none;
                    inline for (0..count) |index| {
                        if (entry.owner == index) {
                            const effect = try entry.call(entry.context, scope, &connection.values[index], header, output);
                            if (effect == .send) {
                                const bytes = effect.send;
                                if (bytes.len == 0 or bytes.len > output.len or bytes.ptr != output.ptr)
                                    return error.InvalidPhaseOutput;
                            }
                            return effect;
                        }
                    }
                    return error.InvalidPacketOwner;
                }
            }
            return error.UnsupportedProtocol;
        }

        pub fn play(self: *Self, comptime versions: anytype, profile: sessions.Profile, event: sessions.protocol.PlayEvent, output: []u8) !?[]const u8 {
            const handle = profile.connection;
            if (handle.index >= self.connections.len or handle.generation == 0) return error.InvalidConnection;
            const connection = &self.connections[handle.index];
            if (connection.generation != handle.generation) return error.InvalidConnection;

            inline for (versions) |Version| {
                if (profile.protocol == Version.protocol_number) {
                    if (event == .attached or event == .park or event == .disconnect) {
                        connection.play_index = 0;
                        var result: ?[]const u8 = null;
                        inline for (0..count) |index| {
                            const entry = self.phases.entries[index];
                            if (entry.play) |handler| {
                                if (try handler.call(handler.context, profile, &connection.values[index], event, output)) |bytes| {
                                    if (event == .attached or result != null or bytes.len == 0 or bytes.len > output.len or bytes.ptr != output.ptr)
                                        return error.InvalidPhaseOutput;
                                    result = bytes;
                                }
                            }
                        }
                        return result;
                    }

                    inline for (0..count) |index| {
                        const entry = self.phases.entries[index];
                        if (connection.play_index <= index) {
                            if (entry.play) |handler| {
                                const bytes = try handler.call(handler.context, profile, &connection.values[index], event, output);
                                if (bytes) |result| {
                                    if (result.len == 0 or result.len > output.len) return error.InvalidPhaseOutput;
                                    connection.play_index = index + 1;
                                    return result;
                                }
                            }
                        }
                    }
                    connection.play_index = 0;
                    return null;
                }
            }
            return error.UnsupportedProtocol;
        }

        pub fn phase(self: *Self, comptime phase_kind: PhaseKind, scope: sessions.PhaseScope, event: sessions.PhaseEvent, output: []u8) !(if (phase_kind == .login) sessions.LoginStep else sessions.ConfigurationStep) {
            const handle = scope.profile.connection;
            if (handle.index >= self.connections.len or handle.generation == 0) return error.InvalidConnection;
            const connection = &self.connections[handle.index];
            var current = event;

            if (current == .begin) {
                if (connection.generation != handle.generation) {
                    connection.* = .{ .generation = handle.generation, .phase = phase_kind, .active = true };
                    inline for (0..count) |index| connection.values[index] = .{};
                } else {
                    if (connection.active) return error.InvalidPhaseState;
                    connection.phase = phase_kind;
                    connection.active = true;
                    connection.index = 0;
                }
            } else if (!connection.active or connection.generation != handle.generation or connection.phase != phase_kind) return error.InvalidPhaseState;

            inline for (0..count) |index| {
                const entry = self.phases.entries[index];
                if (connection.index <= index) {
                    const handler = if (phase_kind == .login) entry.login else entry.configuration;
                    if (handler) |registered| {
                        var plugin_scope = scope;
                        if (phase_kind == .login) plugin_scope.profile.uuid = scope.identity.?.*;
                        const step = try registered.call(registered.context, plugin_scope, &connection.values[index], current, output);
                        switch (step) {
                            .send => |bytes| {
                                if (bytes.len == 0 or bytes.len > output.len) return error.InvalidPhaseOutput;
                            },
                            .reject => |bytes| {
                                if (bytes.len == 0 or bytes.len > output.len or bytes.ptr != output.ptr) return error.InvalidPhaseOutput;
                            },
                            else => {},
                        }
                        if (step != .done) return step;
                    }
                    connection.index = index + 1;
                    current = .begin;
                }
            }

            connection.active = false;
            return .done;
        }

        pub fn closed(self: *Self, handle: sessions.Handle) void {
            if (handle.index >= self.connections.len or handle.generation == 0) return;
            const connection = &self.connections[handle.index];
            if (connection.generation != handle.generation) return;

            inline for (0..count) |index| {
                if (self.phases.entries[index].closed) |handler| handler.call(handler.context, handle, &connection.values[index]);
            }
            connection.* = .{};
        }

        fn dependencies(self: *Self, comptime T: type, environment: anytype, comptime current_index: usize) T {
            var result: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                @field(result, field.name) = plugin.dependency(field.name, field.type, &self.instances, environment, current_index);
            }
            return result;
        }
    };
}

fn phaseStateTypes(comptime Selections: type) [plugin.selectedCount(Selections)]type {
    var types: [plugin.selectedCount(Selections)]type = undefined;
    inline for (0..types.len) |index| {
        const Plugin = plugin.selectedPlugin(plugin.selectedType(Selections, index));
        types[index] = Plugin.SessionState;
    }
    return types;
}
