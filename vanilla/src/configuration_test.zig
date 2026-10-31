const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");

test "embedded registry preparation matches runtime validation and packet encoding" {
    inline for (protocols.implementations) |Version| {
        var embedded = try Version.RegistryProvider.init(std.testing.failing_allocator);
        defer embedded.deinit(std.testing.failing_allocator);
        var runtime = try Version.RegistryProvider.Builder.read(std.testing.allocator, Version.protocol_number, Version.registry_snapshot, Version.minecraft_name);
        defer runtime.deinit(std.testing.allocator);
        try std.testing.expectEqual(runtime.protocol_number, embedded.protocol_number);
        try std.testing.expectEqual(runtime.packets.values.len, embedded.packets.values.len);
        for (runtime.packets.values, embedded.packets.values) |expected, actual|
            try std.testing.expectEqualSlices(u8, expected.bytes, actual.bytes);
        try std.testing.expectEqual(runtime.registries.len, embedded.registries.len);
        for (runtime.registries, embedded.registries) |expected, actual| {
            try std.testing.expectEqualStrings(expected.name, actual.name);
            try std.testing.expectEqual(expected.entries.len, actual.entries.len);
            for (expected.entries, actual.entries) |name, prepared| try std.testing.expectEqualStrings(name, prepared);
        }
    }
}

const Observer = struct {
    configurations: usize = 0,
    closed_connections: usize = 0,

    pub fn closed(self: *Observer, _: sessions.Handle) void {
        self.closed_connections += 1;
    }

    pub fn handshake(_: *Observer, _: []const u8) !sessions.protocol.Handshake {
        return error.UnexpectedHandshake;
    }
    pub fn status(_: *Observer, _: i32, _: []const u8, _: []u8) !?[]const u8 {
        return error.UnexpectedStatus;
    }
    pub fn login(_: *Observer, _: std.Io, _: sessions.Handle, _: *sessions.protocol.State, _: i32, _: sessions.PhaseEvent, _: []u8) !sessions.LoginStep {
        return error.UnexpectedLogin;
    }
    pub fn configuration(self: *Observer, _: std.Io, _: sessions.Handle, _: *sessions.protocol.State, _: i32, event: sessions.PhaseEvent, _: []u8) !sessions.ConfigurationStep {
        try std.testing.expectEqual(sessions.PhaseEvent.begin, event);
        self.configurations += 1;
        return .done;
    }
    pub fn play(_: *Observer, _: sessions.Profile, _: sessions.protocol.PlayEvent, _: []u8) !?[]const u8 {
        return error.UnexpectedPlay;
    }
    pub fn sessionInput(_: *Observer, comptime phase: sessions.InputPhase, _: sessions.Profile, _: std.Io, _: i96, _: []const u8, _: []u8) !sessions.InputEffect(phase) {
        return error.UnexpectedSessionInput;
    }
};

const PausedTransport = struct {
    pub fn pause(_: *PausedTransport, _: std.Io, _: bool) void {}
    pub fn paused(_: *PausedTransport) bool {
        return true;
    }
    pub fn listenerDescriptor(_: *PausedTransport) i32 {
        return 99;
    }
    pub fn descriptor(_: *PausedTransport, _: sessions.Handle) i32 {
        return 100;
    }
    pub fn adopt(_: *PausedTransport, descriptor_: i32) !sessions.Handle {
        try std.testing.expectEqual(@as(i32, 100), descriptor_);
        return .{ .index = 0, .generation = 1 };
    }
};

fn pendingOutput(comptime Version: type) !void {
    const Endpoint = sessions.Endpoint(.{Version}, Version.Bootstrap, struct { values: [1]sessions.Protocol });
    const Engine = sessions.Engine(Endpoint, Observer);
    const Transport = @FieldType(Engine, "networking");
    const Inheritance = std.meta.Child(@FieldType(Transport, "inheritance"));
    var paused: PausedTransport = .{};
    const transport: Transport = .{ .context = &paused, .vtable = undefined, .inheritance = Inheritance.init(PausedTransport, &paused) };
    var catalog: Endpoint.Protocols = .{ .values = .{.{ .number = Version.protocol_number }} };
    var observer: Observer = .{};
    const config: Engine.Configuration = .{ .connections = 1, .buffer_bytes = 1024, .max_packet = 1021, .max_pending_wire_bytes = 64 * 1024, .protocols = &catalog, .observer = &observer };
    const old = try Engine.init(std.testing.allocator, transport, config);
    defer {
        old.setHandle(0, null);
        old.deinit();
    }
    const connection = &old.connections[0];
    old.setHandle(0, .{ .index = 0, .generation = 1 });
    connection.protocol = &catalog.values[0];
    connection.state = .{ .phase = .negotiating, .uuid = 123, .name_len = 5 };
    @memcpy(connection.state.name[0..5], "alice");
    connection.lifecycle = try Endpoint.init(Version.protocol_number, .login);
    switch (connection.lifecycle.?) {
        inline else => |*value| {
            value.phase = .configuration_ack;
            value.wire.install(@splat(17));
        },
    }
    const lease = old.configurations.acquire().?;
    connection.control_burst = lease;
    connection.control_output = .initBuffer(lease.bytes);
    connection.control_output.items = lease.bytes[0 .. 32 * 1024];
    @memset(connection.control_output.items, 23);
    Endpoint.send(&connection.lifecycle.?, connection.control_output.items);
    const accepted = 123;
    const pending = try std.testing.allocator.dupe(u8, connection.control_output.items[accepted..]);
    defer std.testing.allocator.free(pending);
    connection.output = connection.control_output.items[accepted..];
    connection.output_control = true;
    old.reloading = true;
    try std.testing.expect(try old.park(std.testing.io));
    const queued = connection.saved_output.length;
    try std.testing.expect(queued > pending.len);

    var handoff = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer handoff.deinit();
    try old.writeResume(&handoff.writer);
    try std.testing.expectEqualSlices(u8, pending, handoff.written()[handoff.written().len - queued ..][0..pending.len]);
    try std.testing.expectEqual(@as(u32, 51), std.mem.readInt(u32, handoff.written()[28..32], .little));
    const restored = try Engine.init(std.testing.allocator, transport, config);
    defer {
        restored.setHandle(0, null);
        restored.admitted = 0;
        restored.deinit();
    }
    var reader: std.Io.Reader = .fixed(handoff.written());
    try restored.readResume(std.testing.io, &reader, null);
    try std.testing.expectEqual(handoff.written().len, reader.seek);
    const resumed = &restored.connections[0];
    restored.reloading = true;
    try std.testing.expect(try restored.park(std.testing.io));
    var roundtrip = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer roundtrip.deinit();
    try restored.writeResume(&roundtrip.writer);
    try std.testing.expectEqualSlices(u8, handoff.written(), roundtrip.written());
    restored.restart(std.testing.io);

    var original_bytes: [16]u8 = @splat(42);
    var resumed_bytes = original_bytes;
    Endpoint.send(&connection.lifecycle.?, &original_bytes);
    Endpoint.send(&resumed.lifecycle.?, &resumed_bytes);
    try std.testing.expectEqualSlices(u8, &original_bytes, &resumed_bytes);

    var output: [128]u8 = undefined;
    var poll: sessions.protocol.Poll = .{};
    const context: sessions.protocol.Context(Observer) = .{ .connection = resumed.handle.?, .state = &resumed.state, .protocol = resumed.protocol.?, .output = &output, .io = std.testing.io, .now = 0, .poll = &poll, .reloading = false, .compression_threshold = null, .observer = &observer };
    var packet: [64]u8 = undefined;
    const finish = (try Version.Protocol.configuration.toServer.write(&packet).finish_configuration()).finish();
    try std.testing.expectEqual(null, try Endpoint.advance(Observer, &resumed.lifecycle.?, .{ .packet = finish }, context));
    const start = (try Version.Protocol.play.toServer.write(&packet).configuration_acknowledged()).finish();
    try std.testing.expectEqual(null, try Endpoint.advance(Observer, &resumed.lifecycle.?, .{ .packet = start }, context));
    const generated = (try Endpoint.advance(Observer, &resumed.lifecycle.?, .poll, context)).?;
    const header = try Version.Protocol.configuration.toClient.readHeader(generated);
    try std.testing.expectEqual(Version.Protocol.configuration.toClient.packetId(.finish_configuration), header.id);
    try std.testing.expectEqual(@as(usize, 1), observer.configurations);
    try std.testing.expectEqual(@as(usize, 0), observer.closed_connections);
}

test "reload retains encrypted partial output and restarts configuration without plugin state" {
    inline for (protocols.implementations) |Version| try pendingOutput(Version);
}

test "handoff phase tags have fixed encodings independent of internal enum order" {
    inline for (protocols.implementations) |Version| {
        const Connection = Version.Connection;
        try std.testing.expectEqual(@as(u64, 0x07e23a42aaa36cdd), Connection.resume_format);
        const cases = [_]struct { phase: @FieldType(Connection, "phase"), tag: u8 }{
            .{ .phase = .before_ack, .tag = 0 },
            .{ .phase = .reconfiguration_ack, .tag = 1 },
            .{ .phase = .restart_finish_ack, .tag = 2 },
        };
        for (cases) |case| {
            var connection = Connection.init(.login);
            connection.phase = case.phase;
            var output: [51]u8 = undefined;
            const encoded = try connection.save(&output);
            var expected: [51]u8 = @splat(0);
            expected[0] = case.tag;
            try std.testing.expectEqualSlices(u8, &expected, encoded);
            const restored = try Connection.restore(&expected);
            try std.testing.expectEqual(case.phase, restored.phase);
        }
        var invalid: [51]u8 = @splat(0);
        invalid[0] = 255;
        try std.testing.expectError(error.InvalidResume, Connection.restore(&invalid));
        var connection = Connection.init(.login);
        try std.testing.expectError(error.InvalidResume, connection.save(&invalid));
    }
}

test "frozen Minecraft handoff retains compression and independent cipher feedback" {
    const frozen = "\x02\x01\x01" ++ @as([16]u8, @splat(0x11)) ++ @as([16]u8, @splat(0x22)) ++ @as([16]u8, @splat(0x33));
    inline for (protocols.implementations) |Version| {
        var connection = Version.Connection.init(.login);
        connection.phase = .restart_finish_ack;
        connection.wire.compressed = true;
        connection.wire.install(@splat(0x11));
        connection.wire.receive_cipher.?.feedback = @splat(0x22);
        connection.wire.send_cipher.?.feedback = @splat(0x33);
        var buffer: [51]u8 = undefined;
        try std.testing.expectEqualSlices(u8, frozen, try connection.save(&buffer));
        const restored = try Version.Connection.restore(frozen);
        try std.testing.expectEqual(connection.phase, restored.phase);
        try std.testing.expect(restored.wire.compressed);
        try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0x11)), &restored.wire.receive_cipher.?.secret);
        try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0x22)), &restored.wire.receive_cipher.?.feedback);
        try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0x33)), &restored.wire.send_cipher.?.feedback);
        var original_output: [16]u8 = @splat(0x44);
        var restored_output = original_output;
        var resumed = restored;
        connection.send(&original_output);
        resumed.send(&restored_output);
        try std.testing.expectEqualSlices(u8, &original_output, &restored_output);
    }
}
