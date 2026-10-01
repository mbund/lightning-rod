const std = @import("std");
const source = @import("source");
const target = @import("target");
const options = @import("options");
const support = @import("support");

const Number = source.Entry.cases.value.number;
const Payload = source.Payload.cases.value.number;
const Custom = struct {
    pub const protocol_number = 9002;
    pub const Protocol = target;
    pub const Payload = target.Payload;
    pub const case_tags = target.case_tags;
};
const schemas = .{ source, target, Custom };
const Dispatch = support.cursor.Dispatch(schemas, "Payload", "value", *i32, i32);

const Owner = struct {
    fn read(packet: Payload.Payload.Reader, _: *@This(), output: *i32) !Payload.Payload.Reader.Done {
        output.*, const done = try packet.value();
        return done;
    }

    fn write(packet: Payload.Payload.Writer, _: *@This(), value: i32) !Payload.Payload.Writer.Done {
        return packet.value(value);
    }
};

fn writeOld(packet: Payload.Writer, value: i64) !Payload.Writer.Done {
    return (try packet.type()).value(@intCast(value));
}

fn writeNew(packet: target.Payload.cases.value.number.Writer, value: i64) !target.Payload.cases.value.number.Writer.Done {
    return (try packet.type()).value(value);
}

fn writeList(packet: source.List.Writer, value: i64) !source.List.Writer.Done {
    var entries = try packet.value(1);
    try entries.advance(try support.cursor.Nested(schemas, .{writeOld}).write((try entries.next()).?, value));
    return entries.finish();
}

fn writeMaybe(packet: source.Maybe.Writer, value: i64) !source.Maybe.Writer.Done {
    var child = try packet.some();
    return child.advance(try support.cursor.Nested(schemas, .{writeOld}).write(try child.begin(), value));
}

pub fn main() !void {
    var buffer: [64]u8 = undefined;
    var outer = source.Outer.write(&buffer);
    outer._cursor.protocol_number = Custom.protocol_number;
    outer._cursor.layout_protocol = target.protocol_number;
    var child = try outer.entry();
    const destination = try child.begin();

    if (comptime std.mem.eql(u8, options.mode, "nested_changed")) {
        _ = try support.cursor.Nested(schemas, .{writeOld}).write(destination, 42);
        return;
    }
    if (comptime std.mem.eql(u8, options.mode, "nested_missing")) {
        _ = try support.cursor.Nested(schemas, .{writeNew}).write(destination, 42);
        return;
    }
    if (comptime std.mem.eql(u8, options.mode, "nested_upgrade")) {
        comptime source.Outer.Writer.requireCompatible(target.Outer.Writer);
        const done = try support.cursor.Nested(schemas, .{ writeOld, writeNew }).write(destination, 42);
        const bytes = (try child.advance(done)).finish();
        std.debug.assert(std.mem.eql(u8, bytes, &.{ 19, 42 }));
        return;
    }
    if (comptime std.mem.eql(u8, options.mode, "wrong_completion")) {
        const done: source.Maybe.Completion = .{ ._cursor = destination._cursor };
        _ = try child.advance(done);
        return;
    }
    if (comptime std.mem.eql(u8, options.mode, "full")) {
        comptime source.Entry.Writer.requireCompatible(target.Entry.Writer);
        return;
    }
    if (comptime !std.mem.eql(u8, options.mode, "dispatch_payload")) {
        comptime Number.Writer.requireCompatible(target.Entry.Writer);
        var packet = Number.write(&buffer);
        packet._cursor.protocol_number = target.protocol_number;
        packet._cursor.tags = target.case_tags;
        const done = try (try (try packet.key(5)).type()).value(42);
        std.debug.assert(std.mem.eql(u8, done.finish(), &.{ 5, 19, 0, 0, 0, 42 }));
    }

    var owner: Owner = .{};
    var registry = try Dispatch.init(std.heap.page_allocator, 1);
    defer std.heap.page_allocator.free(registry.entries);
    try registry.on(.number, &owner, .{ .read = Owner.read, .write = Owner.write });
    if (registry.on(.number, &owner, .{ .read = Owner.read, .write = Owner.write })) |_| return error.AcceptedDuplicateOwner else |err| if (err != error.DuplicateCaseOwner) return err;

    comptime source.Outer.Writer.requireCompatible(target.Outer.Writer);
    const completed = try registry.write(destination, Dispatch.key(.number), 42);
    var unrelated = try outer.entry();
    _ = try unrelated.begin();
    if (unrelated.advance(completed)) |_| return error.AcceptedWrongOwner else |err| if (err != error.InvalidCompletion) return err;
    const bytes = (try child.advance(completed)).finish();
    std.debug.assert(std.mem.eql(u8, bytes, &.{ 19, 0, 0, 0, 42 }));
    if (child.advance(completed)) |_| return error.AcceptedDoubleCompletion else |err| if (err != error.InvalidCompletion) return err;

    var value: i32 = 0;
    const identifier = try registry.readPayload(Custom.protocol_number, 19, bytes[1..], &value);
    std.debug.assert(identifier == Dispatch.key(.number) and value == 42);
    if (registry.on(.number, &owner, .{ .read = Owner.read, .write = Owner.write })) |_| return error.AcceptedLateRegistration else |err| if (err != error.RegistrationClosed) return err;
    if (registry.readPayload(Custom.protocol_number, 20, bytes[1..], &value)) |_| return error.AcceptedUnregisteredTag else |err| if (err != error.UnsupportedComponent) return err;

    var extras = source.Extras.write(&buffer);
    extras._cursor.protocol_number = target.protocol_number;
    var list = try extras.entries();
    const after = try list.advance(try support.cursor.Nested(schemas, .{writeList}).write(try list.begin(), 42));
    var optional = try after.optional();
    const end = try optional.advance(try support.cursor.Nested(schemas, .{writeMaybe}).write(try optional.begin(), 17));
    std.debug.assert(std.mem.eql(u8, end.finish(), &.{ 1, 19, 0, 0, 0, 42, 1, 19, 0, 0, 0, 17 }));
}
