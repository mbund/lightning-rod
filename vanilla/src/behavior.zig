const std = @import("std");
const values = @import("content_values.zig");

pub fn Binding(comptime Context: type, comptime Result: type) type {
    return struct {
        const Self = @This();
        context: *anyopaque,
        vtable: *const VTable,
        const VTable = struct {
            call: *const fn (*anyopaque, *const Context) anyerror!Result,
            copy: *const fn (*anyopaque, std.mem.Allocator) anyerror!Self,
        };
        pub const Selection = union(enum) {
            inherit,
            declarative,
            custom: Self,

            pub fn resolve(self: *const @This(), previous: ?*const Self) ?*const Self {
                return switch (self.*) {
                    .inherit => previous,
                    .declarative => null,
                    .custom => |*binding| binding,
                };
            }
        };

        pub fn call(self: Self, context: *const Context) !Result {
            return self.vtable.call(self.context, context);
        }

        pub fn cloneContent(self: Self, allocator: std.mem.Allocator) !Self {
            return self.vtable.copy(self.context, allocator);
        }

        /// The owner must outlive every registry using this binding.
        pub fn bind(comptime Owner: type, owner: *Owner, comptime function: fn (*Owner, *const Context) anyerror!Result) Self {
            const Adapter = struct {
                const vtable: VTable = .{ .call = invoke, .copy = copy };
                fn invoke(raw: *anyopaque, context: *const Context) anyerror!Result {
                    const typed: *Owner = @ptrCast(@alignCast(raw));
                    return function(typed, context);
                }
                fn copy(raw: *anyopaque, _: std.mem.Allocator) anyerror!Self {
                    return .{ .context = raw, .vtable = &vtable };
                }
            };
            return .{ .context = owner, .vtable = &Adapter.vtable };
        }

        pub fn Handler(comptime Owner: type, comptime Parameters: type, comptime callback: fn (*Owner, *const Parameters, *const Context) anyerror!Result) type {
            return struct {
                const Bound = struct { owner: *Owner, parameters: Parameters };
                const HandlerType = @This();
                const vtable: VTable = .{ .call = invoke, .copy = copy };

                /// Parameters are owned. The callback owner must outlive the binding.
                pub fn define(allocator: std.mem.Allocator, owner: *Owner, parameters: Parameters) !Self {
                    const bound = try allocator.create(Bound);
                    bound.* = .{ .owner = owner, .parameters = try values.clone(allocator, parameters, 0) };
                    return .{ .context = bound, .vtable = &vtable };
                }

                fn castState(raw: *anyopaque) *Bound {
                    return @ptrCast(@alignCast(raw));
                }

                fn invoke(raw: *anyopaque, context: *const Context) !Result {
                    const state = castState(raw);
                    return callback(state.owner, &state.parameters, context);
                }

                fn copy(raw: *anyopaque, allocator: std.mem.Allocator) !Self {
                    const state = castState(raw);
                    return HandlerType.define(allocator, state.owner, state.parameters);
                }
            };
        }
    };
}
