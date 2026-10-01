const std = @import("std");
const cursor = @import("cursor.zig");
const layout = @import("layout.zig");

/// An open tagged-record boundary. Registration checks concrete payload codecs
/// against every selected schema. Unregistered tags are rejected without scanning.
pub fn Dispatch(comptime schemas: anytype, comptime name: []const u8, comptime field: []const u8, comptime ReadContext: type, comptime WriteContext: type) type {
    return struct {
        const Self = @This();
        pub const wire_type_name = name;
        pub const Key = u64;
        pub const Tag = @field(@field(schemas[0], name).cases, field).Tag;

        const Codec = struct {
            tag: i128,
            read: *const fn (*anyopaque, cursor.State(.read), ReadContext) anyerror!cursor.State(.read),
            write: *const fn (*anyopaque, cursor.State(.write), WriteContext) anyerror!cursor.State(.write),
        };
        pub const Entry = struct {
            key: Key,
            name: []const u8,
            context: *anyopaque,
            codecs: [schemas.len]Codec,
        };

        entries: []Entry,
        count: usize = 0,
        sealed: bool = false,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return .{ .entries = try allocator.alloc(Entry, capacity) };
        }

        pub fn key(comptime tag: anytype) Key {
            return layout.nameKey(@tagName(tag));
        }

        pub fn on(self: *Self, comptime tag: Tag, context: anytype, comptime handlers: anytype) !void {
            if (self.sealed) return error.RegistrationClosed;
            for (self.entries[0..self.count]) |entry| {
                if (entry.key == key(tag)) return error.DuplicateCaseOwner;
            }
            if (self.count == self.entries.len) return error.DispatchCapacity;
            var entry: Entry = .{ .key = key(tag), .name = @tagName(tag), .context = context, .codecs = undefined };
            inline for (schemas, 0..) |Schema, index| {
                const Record = @field(Schema, name);
                const Cases = @field(Record.cases, field);
                const Case = @field(Cases, @tagName(tag));
                if (!Cases.tagged_record) @compileError("dispatch requires a tag followed by its payload");
                const readers = layout.candidates(handlers.read);
                const writers = layout.candidates(handlers.write);
                const read_index = comptime layout.selectCase(readers, Record.Reader.protocol_number, null) orelse @compileError("no reader for " ++ @tagName(tag));
                const write_index = comptime layout.selectCase(writers, Record.Writer.protocol_number, null) orelse @compileError("no writer for " ++ @tagName(tag));
                const Reader = layout.callbackCursor(readers[read_index]);
                const Writer = layout.callbackCursor(writers[write_index]);
                comptime {
                    if (!std.mem.eql(u8, Reader.cursor_mode, "read") or !std.mem.eql(u8, Writer.cursor_mode, "write")) @compileError("incorrect codec direction");
                    if (Reader.requires_parent_context or Writer.requires_parent_context or
                        Case.Payload.Reader.requires_parent_context or Case.Payload.Writer.requires_parent_context)
                        @compileError("dispatch payload depends on preceding fields. Encode the enclosing record instead.");
                    if (@typeInfo(@typeInfo(@TypeOf(readers[read_index])).@"fn".return_type.?).error_union.payload != Reader.Done or
                        @typeInfo(@typeInfo(@TypeOf(writers[write_index])).@"fn".return_type.?).error_union.payload != Writer.Done)
                        @compileError("dispatch callbacks must return their concrete cursor's Done value");
                    Reader.requireCompatible(Case.Payload.Reader);
                    Writer.requireCompatible(Case.Payload.Writer);
                }
                entry.codecs[index] = .{
                    .tag = @intFromEnum(@field(Cases.Tag, @tagName(tag))),
                    .read = struct {
                        fn read(raw: *anyopaque, state: cursor.State(.read), arguments: ReadContext) !cursor.State(.read) {
                            const plugin: @TypeOf(context) = @ptrCast(@alignCast(raw));
                            const done = try readers[read_index](Reader{ ._cursor = state }, plugin, arguments);
                            var validated = state;
                            try validated.accept(done._cursor, validated.owner, validated.serial);
                            return validated;
                        }
                    }.read,
                    .write = struct {
                        fn write(raw: *anyopaque, state: cursor.State(.write), arguments: WriteContext) !cursor.State(.write) {
                            const plugin: @TypeOf(context) = @ptrCast(@alignCast(raw));
                            const record: Case.Writer = .{ ._cursor = state };
                            const payload = try @field(Case.Writer, Cases.tag_field)(record);
                            const done = try writers[write_index](Writer{ ._cursor = payload._cursor, ._context = cursor.context(Writer.Context, payload._context) }, plugin, arguments);
                            var validated = state;
                            try validated.accept(done._cursor, validated.owner, validated.serial);
                            return validated;
                        }
                    }.write,
                };
            }
            self.entries[self.count] = entry;
            self.count += 1;
        }

        pub fn find(self: *const Self, wanted: Key) ?*const Entry {
            for (self.entries[0..self.count]) |*entry| if (entry.key == wanted) return entry;
            return null;
        }

        pub fn readPayload(self: *Self, protocol: i32, tag: i128, bytes: []const u8, arguments: ReadContext) !Key {
            self.sealed = true;
            inline for (schemas, 0..) |Schema, index| {
                if (protocol == Schema.protocol_number) {
                    for (self.entries[0..self.count]) |*entry| {
                        if (entry.codecs[index].tag != tag) continue;
                        const done = try entry.codecs[index].read(entry.context, .{ .buffer = bytes, .rest = bytes, .origin = @intFromPtr(bytes.ptr), .protocol_number = protocol, .layout_protocol = @field(Schema, name).Reader.protocol_number }, arguments);
                        if (done.rest.len != 0) return error.ExtraDataAfterEndOfPacket;
                        return entry.key;
                    }
                    return error.UnsupportedComponent;
                }
            }
            return error.UnsupportedProtocol;
        }

        pub fn keyForTag(self: *const Self, protocol: i32, tag: i128) !Key {
            inline for (schemas, 0..) |Schema, index| {
                if (protocol == Schema.protocol_number) {
                    for (self.entries[0..self.count]) |*entry| if (entry.codecs[index].tag == tag) return entry.key;
                    return error.UnsupportedComponent;
                }
            }
            return error.UnsupportedProtocol;
        }

        pub fn tagForKey(self: *const Self, protocol: i32, identifier: Key) !i128 {
            const entry = self.find(identifier) orelse return error.UnsupportedComponent;
            inline for (schemas, 0..) |Schema, index| if (protocol == Schema.protocol_number) return entry.codecs[index].tag;
            return error.UnsupportedProtocol;
        }

        pub fn write(self: *Self, destination: cursor.Destination(name), identifier: Key, arguments: WriteContext) !cursor.Destination(name).Done {
            self.sealed = true;
            const entry = self.find(identifier) orelse return error.UnsupportedComponent;
            inline for (schemas, 0..) |Schema, index| {
                if (destination._cursor.protocol_number == Schema.protocol_number) {
                    var state = destination._cursor;
                    state.tags = Schema.case_tags;
                    state.layout_protocol = @field(Schema, name).Writer.protocol_number;
                    const done = try entry.codecs[index].write(entry.context, state, arguments);
                    try state.accept(done, state.owner, state.serial);
                    state.tags = destination._cursor.tags;
                    state.layout_protocol = destination._cursor.layout_protocol;
                    return .{ ._cursor = state };
                }
            }
            return error.UnsupportedProtocol;
        }
    };
}
