const std = @import("std");
const protocol_support = @import("protocol_support.zig");


pub const handshaking = struct {
    pub const toServer = struct {
        pub const Cursor0 = struct {
            buffer: []const u8;
            // variants
        }
        
        pub const Cursor1 = struct {
            buffer: []const u8;
            // simple
            // .{ .readType = .{ .native = .varint }, .next = .{ .name = { 67, 117, 114, 115, 111, 114, 50 }, .kind = .{ .simple = .{ ... } }, .visited = false } }
        }
        
        pub const Cursor2 = struct {
            buffer: []const u8;
            // simple
            // .{ .readType = .{ .pstring = .varint }, .next = .{ .name = { 67, 117, 114, 115, 111, 114, 51 }, .kind = .{ .simple = .{ ... } }, .visited = false } }
        }
        
        pub const Cursor3 = struct {
            buffer: []const u8;
            // simple
            // .{ .readType = .{ .native = .u16 }, .next = .{ .name = { 67, 117, 114, 115, 111, 114, 52 }, .kind = .{ .simple = .{ ... } }, .visited = false } }
        }
        
        pub const Cursor4 = struct {
            buffer: []const u8;
            // simple
            // .{ .readType = .{ .native = .varint }, .next = null }
        }
        
        pub const Cursor5 = struct {
            buffer: []const u8;
            // simple
            // .{ .readType = .{ .native = .u8 }, .next = null }
        }
        
        pub const Cursor6 = struct {
            buffer: []const u8;
            // simple
            // .{ .readType = .{ .native = .void }, .next = null }
        }
        
    };
};


