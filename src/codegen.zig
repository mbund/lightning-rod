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
            pub fn next() !struct { protocolVersion: i32, cursor: packet__set_protocol__params__serverHost } {
                }
            }
            
            pub const packet__set_protocol__params__serverHost = struct {
                buffer: []const u8;
                pub fn next() !struct { serverHost: []const u8, cursor: packet__set_protocol__params__serverPort } {
                    }
                }
                
                pub const packet__set_protocol__params__serverPort = struct {
                    buffer: []const u8;
                    pub fn next() !struct { serverPort: u16, cursor: packet__set_protocol__params__nextState } {
                        }
                    }
                    
                    pub const packet__set_protocol__params__nextState = struct {
                        buffer: []const u8;
                        pub fn next() !struct { nextState: i32, cursor: FinalCursor } {
                            }
                        }
                        
                        pub const packet__legacy_server_list_ping__params__payload = struct {
                            buffer: []const u8;
                            pub fn next() !struct { payload: u8, cursor: FinalCursor } {
                                }
                            }
                            
                            pub const packet__params = struct {
                                buffer: []const u8;
                                pub fn next() !struct { params: protocol_support.void, cursor: FinalCursor } {
                                    }
                                }
                                
                            };
                        };

                        
