const std = @import("std");
const protocol_support = @import("protocol_support.zig");


pub const handshaking = struct {
    pub const toServer = struct {
        pub fn read(buffer: []const u8) packet__name {
            return .{ .buffer = buffer };
        }
        
        pub const packet__name = struct {
            buffer: []const u8,
            
            pub fn name(self: @This()) !union(enum) {
                set_protocol: packet__set_protocol__params__protocolVersion,
                legacy_server_list_ping: packet__legacy_server_list_ping__params__payload,
                default: packet__params,
            } {
                const value, const rest = read_varint(self.buffer);
                return switch (value) {
                    0 => .{ .set_protocol = .{ .buffer = rest } };
                    254 => .{ .legacy_server_list_ping = .{ .buffer = rest } };
                    else => .{ .default = .{ .buffer = rest } };
                };
            }
        };
        
        pub const packet__set_protocol__params__protocolVersion = struct {
            buffer: []const u8,
            
            pub fn protocolVersion(self: @This()) !struct { i32, packet__set_protocol__params__serverHost } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };
        
        pub const packet__set_protocol__params__serverHost = struct {
            buffer: []const u8,
            
            pub fn serverHost(self: @This()) !struct { []const u8, packet__set_protocol__params__serverPort } {
                const length, const rest = try protocol_support.read_varint(self.buffer);
                return .{ rest[0..length], .{.buffer = rest[length..] } };
            }
        };
        
        pub const packet__set_protocol__params__serverPort = struct {
            buffer: []const u8,
            
            pub fn serverPort(self: @This()) !struct { u16, packet__set_protocol__params__nextState } {
                const value, const rest = try protocol_support.read_u16(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };
        
        pub const packet__set_protocol__params__nextState = struct {
            buffer: []const u8,
            
            pub fn nextState(self: @This()) !struct { i32, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_varint(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };
        
        pub const packet__legacy_server_list_ping__params__payload = struct {
            buffer: []const u8,
            
            pub fn payload(self: @This()) !struct { u8, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_u8(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };
        
        pub const packet__params = struct {
            buffer: []const u8,
            
            pub fn params(self: @This()) !struct { protocol_support.void, protocol_support.FinalCursor } {
                const value, const rest = try protocol_support.read_void(self.buffer);
                return .{ value, .{ .buffer = rest } };
            }
        };
        
    };
};


