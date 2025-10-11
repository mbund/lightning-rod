const std = @import("std");
const protocol_support = @import("protocol_support.zig");


pub const handshaking = struct {
    pub const toServer = struct {
        pub const packet = struct {
            buffer: []const u8;
            // variants
        }
        
        pub const packet__set_protocol__params__protocolVersion = struct {
            buffer: []const u8;
            // simple
            // .{ .readType = .{ .native = .varint }, .next = .{ .name = { 112, 97, 99, 107, 101, 116, 95, 95, 115, 101, 116, 95, 112, 114, 111, 116, 111, 99, 111, 108, 95, 95, 112, 97, 114, 97, 109, 115, 95, 95, 115, 101, 114, 118, 101, 114, 72, 111, 115, 116 }, .kind = .{ .simple = .{ ... } }, .visited = false } }
        }
        
        pub const packet__set_protocol__params__serverHost = struct {
            buffer: []const u8;
            // simple
            // .{ .readType = .{ .pstring = .varint }, .next = .{ .name = { 112, 97, 99, 107, 101, 116, 95, 95, 115, 101, 116, 95, 112, 114, 111, 116, 111, 99, 111, 108, 95, 95, 112, 97, 114, 97, 109, 115, 95, 95, 115, 101, 114, 118, 101, 114, 80, 111, 114, 116 }, .kind = .{ .simple = .{ ... } }, .visited = false } }
        }
        
        pub const packet__set_protocol__params__serverPort = struct {
            buffer: []const u8;
            // simple
            // .{ .readType = .{ .native = .u16 }, .next = .{ .name = { 112, 97, 99, 107, 101, 116, 95, 95, 115, 101, 116, 95, 112, 114, 111, 116, 111, 99, 111, 108, 95, 95, 112, 97, 114, 97, 109, 115, 95, 95, 110, 101, 120, 116, 83, 116, 97, 116, 101 }, .kind = .{ .simple = .{ ... } }, .visited = false } }
        }
        
        pub const packet__set_protocol__params__nextState = struct {
            buffer: []const u8;
            // simple
            // .{ .readType = .{ .native = .varint }, .next = null }
        }
        
        pub const packet__legacy_server_list_ping__params__payload = struct {
            buffer: []const u8;
            // simple
            // .{ .readType = .{ .native = .u8 }, .next = null }
        }
        
        pub const packet__params = struct {
            buffer: []const u8;
            // simple
            // .{ .readType = .{ .native = .void }, .next = null }
        }
        
    };
};


