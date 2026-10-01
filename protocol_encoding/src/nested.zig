const std = @import("std");
const cursor = @import("cursor.zig");
const layout = @import("layout.zig");

/// Each handler owns one concrete schema. Arguments are the same concrete type
/// across handlers. The destination owns the actual protocol and output buffer.
pub fn Encoder(comptime schemas: anytype, comptime callbacks: anytype) type {
    const handlers = layout.candidates(callbacks);
    if (handlers.len == 0) @compileError("nested encoding requires at least one handler");
    const First = layout.callbackCursor(handlers[0]);
    const name = First.wire_type_name;
    const Parameters = @typeInfo(@TypeOf(handlers[0])).@"fn".params;
    if (Parameters.len != 2) @compileError("nested writers take a concrete cursor and one concrete argument type");
    const Arguments = Parameters[1].type orelse @compileError("nested arguments must have a concrete type");
    const Output = cursor.Destination(name);
    const selected = comptime selection: {
        var indices: [schemas.len]?usize = @splat(null);
        for (handlers, 0..) |handler, index| {
            const Source = layout.callbackCursor(handler);
            const Function = @typeInfo(@TypeOf(handler)).@"fn";
            if (Function.params.len != 2 or Function.params[1].type != Arguments)
                @compileError("nested writers must use the same concrete arguments");
            if (!std.mem.eql(u8, Source.wire_type_name, name) or !std.mem.eql(u8, Source.cursor_mode, "write") or
                Source.requires_parent_context or !layout.sameCase(Source.restricted_case, First.restricted_case))
                @compileError("nested writers must encode the same self-contained schema and case");
            if (@typeInfo(Function.return_type.?).error_union.payload != Source.Done)
                @compileError("nested writer must return its concrete cursor's Done");
            for (0..index) |previous| if (layout.callbackCursor(handlers[previous]).protocol_number == Source.protocol_number)
                @compileError("duplicate nested writer source protocol");
        }
        for (schemas, &indices) |Schema, *index| {
            const Wire = if (@hasDecl(Schema, "Protocol")) Schema.Protocol else Schema;
            const Actual = layout.destinationWriter(Wire, First) orelse continue;
            index.* = layout.selectCase(handlers, Actual.protocol_number, First.restricted_case) orelse
                @compileError("no nested writer for " ++ name);
            layout.callbackCursor(handlers[index.*.?]).requireCompatible(Actual);
        }
        break :selection indices;
    };
    return struct {
        pub fn write(destination: Output, args: Arguments) !Output.Done {
            inline for (schemas, selected) |Schema, index| {
                if (comptime index == null) continue;
                if (destination._cursor.protocol_number == Schema.protocol_number) {
                    const Source = layout.callbackCursor(handlers[index.?]);
                    const Wire = if (@hasDecl(Schema, "Protocol")) Schema.Protocol else Schema;
                    var state = destination._cursor;
                    state.layout_protocol = Wire.protocol_number;
                    state.tags = Wire.case_tags;
                    const start = state;
                    const done = try handlers[index.?](Source{ ._cursor = state }, args);
                    try state.accept(done._cursor, start.owner, start.serial);
                    state.layout_protocol = destination._cursor.layout_protocol;
                    state.tags = destination._cursor.tags;
                    var checked = destination._cursor;
                    try checked.accept(state, checked.owner, checked.serial);
                    return .{ ._cursor = checked };
                }
            }
            return error.UnsupportedProtocol;
        }
    };
}
