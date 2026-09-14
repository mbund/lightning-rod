const std = @import("std");
const chunks = @import("chunks");
const minecraft = @import("minecraft");
const Players = @import("players.zig").Players;

pub const BlockActions = struct {
    pub const id = "minecraft:block_actions";

    pub const Configuration = struct { maximum: usize = 32 };

    pub const Request = struct {
        action: enum { place, use, remove },
        player: *const Players.Player,
        position: chunks.Position,
        state: u16,
        hit: ?minecraft.Place = null,
    };

    pub const Result = enum { pass, applied, denied };

    pub const Handler = struct {
        minimum: u16,
        maximum: u16,
        context: *anyopaque,
        apply: *const fn (*anyopaque, Request) anyerror!Result,
    };

    handlers: []Handler,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration) !*BlockActions {
        const self = try allocator.create(BlockActions);
        self.* = .{ .handlers = try allocator.alloc(Handler, config.maximum) };
        return self;
    }

    pub fn register(self: *BlockActions, handler: Handler) !void {
        std.debug.assert(handler.minimum <= handler.maximum);

        for (self.handlers[0..self.count]) |previous| {
            if (handler.minimum <= previous.maximum and previous.minimum <= handler.maximum) return error.OverlappingBlockActions;
        }

        if (self.count == self.handlers.len) return error.BlockActionCapacity;
        self.handlers[self.count] = handler;
        self.count += 1;
    }

    pub fn apply(self: *BlockActions, request: Request) !Result {
        for (self.handlers[0..self.count]) |handler| {
            if (request.state >= handler.minimum and request.state <= handler.maximum) return handler.apply(handler.context, request);
        }

        return .pass;
    }
};
