const std = @import("std");

pub fn clone(allocator: std.mem.Allocator, value: anytype, depth: usize) anyerror!@TypeOf(value) {
    if (depth >= 64) return error.ContentDepthLimit;
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct", .@"union" => if (@hasDecl(T, "cloneContent")) return value.cloneContent(allocator),
        else => {},
    }
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => result: {
                const values = try allocator.alloc(pointer.child, value.len);
                for (value, values) |source, *target| target.* = try clone(allocator, source, depth + 1);
                break :result values;
            },
            .one => result: {
                if (@typeInfo(pointer.child) == .@"opaque" or @typeInfo(pointer.child) == .@"fn") break :result value;
                const copied = try allocator.create(pointer.child);
                copied.* = try clone(allocator, value.*, depth + 1);
                break :result copied;
            },
            else => @compileError("content definitions require bounded pointers"),
        },
        .@"struct" => |info| result: {
            var copied: T = undefined;
            inline for (info.fields) |field| if (!field.is_comptime) {
                @field(copied, field.name) = try clone(allocator, @field(value, field.name), depth + 1);
            };
            break :result copied;
        },
        .@"union" => result: {
            switch (value) {
                inline else => |payload, tag| break :result @unionInit(T, @tagName(tag), try clone(allocator, payload, depth + 1)),
            }
        },
        .optional => if (value) |present| try clone(allocator, present, depth + 1) else null,
        .array => result: {
            var copied: T = undefined;
            for (value, &copied) |source, *target| target.* = try clone(allocator, source, depth + 1);
            break :result copied;
        },
        else => value,
    };
}
