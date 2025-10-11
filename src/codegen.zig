const std = @import("std");
const protocol_support = @import("protocol_support.zig");


pub const handshaking = struct {
    pub const toServer = struct {
        const Cursor0 = struct {
            buffer: []const u8;
        }
        
        const Cursor1 = struct {
            // previous Cursor0
            buffer: []const u8;
        }
        
        const Cursor5 = struct {
            // previous Cursor0
            buffer: []const u8;
        }
        
        const Cursor6 = struct {
            // previous Cursor0
            buffer: []const u8;
        }
        
    };
};


