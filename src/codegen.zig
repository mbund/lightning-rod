const std = @import("std");
const protocol_support = @import("protocol_support.zig");

pub const previousMessages = []struct {
    id: i32,
    signature: protocol_support.Todo,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_varint(&self.id);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        
    }
};

pub const chunkBlockEntity = struct {
    anon: protocol_support.Todo,
    y: i16,
    type: i32,
    nbtData: protocol_support.optionalNbt,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try protocol_support.todo(r, &self.anon);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_i16(&self.y);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_varint(&self.type);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_optionalNbt(&self.nbtData);
    }
};

pub const entityMetadata = protocol_support.Todo;

pub const vec3f = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_f32(&self.x);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_f32(&self.y);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_f32(&self.z);
    }
};

pub const ItemSoundHolder = protocol_support.Todo;

pub const packedChunkPos = struct {
    z: i32,
    x: i32,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_i32(&self.z);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_i32(&self.x);
    }
};

pub const tags = []struct {
    tagName: string,
    entries: []i32,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        try protocol_support.todo(r, &self.tagName);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        var length_0: i32 = undefined;
        try r.read_varint(&length_0);
        self.entries = allocator.alloc(@TypeOf(self.entries[0]), length_0);
        for (0..length_0) |i_0| {
            // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
            try r.read_varint(&self.entries[i_0]);
        }
    }
};

pub const soundSource = protocol_support.Todo;

pub const vec4f = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_f32(&self.x);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_f32(&self.y);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_f32(&self.z);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_f32(&self.w);
    }
};

pub const minecraft_simple_recipe_format = struct {
    category: i32,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
        try r.read_varint(&self.category);
    }
};

pub const minecraft_smelting_format = struct {
    group: string,
    category: i32,
    ingredient: ingredient,
    result: slot,
    experience: f32,
    cookTime: i32,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try protocol_support.todo(r, &self.group);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_varint(&self.category);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        var length_0: i32 = undefined;
        try r.read_varint(&length_0);
        self.ingredient = allocator.alloc(@TypeOf(self.ingredient[0]), length_0);
        for (0..length_0) |i_0| {
            // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
            try self.ingredient[i_0].read(r, allocator);
        }
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try self.result.read(r, allocator);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_f32(&self.experience);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_varint(&self.cookTime);
    }
};

pub const chat_session = protocol_support.Todo;

pub const ingredient = []slot;

pub const slot = struct {
    present: bool,
    anon: protocol_support.Todo,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_bool(&self.present);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        
    }
};

pub const string = protocol_support.Todo;

pub const particle = struct {
    particleId: i32,
    data: protocol_support.Todo,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_varint(&self.particleId);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        try protocol_support.todo(r, &self.data);
    }
};

pub const ByteArray = protocol_support.Todo;

pub const command_node = struct {
    flags: protocol_support.Todo,
    children: []i32,
    redirectNode: protocol_support.Todo,
    extraNodeData: protocol_support.Todo,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try protocol_support.todo(r, &self.flags);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        var length_0: i32 = undefined;
        try r.read_varint(&length_0);
        self.children = allocator.alloc(@TypeOf(self.children[0]), length_0);
        for (0..length_0) |i_0| {
            // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
            try r.read_varint(&self.children[i_0]);
        }
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        
    }
};

pub const ItemSoundEvent = struct {
    soundName: string,
    fixedRange: protocol_support.Todo,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        try protocol_support.todo(r, &self.soundName);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        try protocol_support.todo(r, &self.fixedRange);
    }
};

pub const game_profile = struct {
    name: string,
    properties: []struct {
        name: string,
        value: string,
        signature: protocol_support.Todo,

        pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
            protocol_support.maybe_unused(allocator);
            protocol_support.maybe_unused(r);
            protocol_support.maybe_unused(self);
            // parent_type null grandparent_type null
            // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
            try protocol_support.todo(r, &self.name);
            // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
            try protocol_support.todo(r, &self.value);
            // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
            try protocol_support.todo(r, &self.signature);
        }
    },

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        try protocol_support.todo(r, &self.name);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
        var length_0: i32 = undefined;
        try r.read_varint(&length_0);
        self.properties = allocator.alloc(@TypeOf(self.properties[0]), length_0);
        for (0..length_0) |i_0| {
            // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
            // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }
            try protocol_support.todo(r, &self.properties[i_0].name);
            // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }
            try protocol_support.todo(r, &self.properties[i_0].value);
            // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } }
            try protocol_support.todo(r, &self.properties[i_0].signature);
        }
    }
};

pub const vec3f64 = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        // parent_type null grandparent_type null
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_f64(&self.x);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_f64(&self.y);
        // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
        try r.read_f64(&self.z);
    }
};


pub const handshaking = struct {
    pub const toClient = struct {
        pub const packet = struct {
            name: protocol_support.Todo,
            params: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.name);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                
            }
        };


    };
    pub const toServer = struct {
        pub const packet_set_protocol = struct {
            protocolVersion: i32,
            serverHost: string,
            serverPort: u16,
            nextState: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.protocolVersion);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.serverHost);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_u16(&self.serverPort);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.nextState);
            }
        };

        pub const packet = struct {
            name: protocol_support.Todo,
            params: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.name);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                
            }
        };

        pub const packet_legacy_server_list_ping = struct {
            payload: u8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                try r.read_u8(&self.payload);
            }
        };


    };
};pub const status = struct {
    pub const toClient = struct {
        pub const packet_ping = struct {
            time: i64,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                try r.read_i64(&self.time);
            }
        };

        pub const packet = struct {
            name: protocol_support.Todo,
            params: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.name);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                
            }
        };

        pub const packet_server_info = struct {
            response: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.response);
            }
        };


    };
    pub const toServer = struct {
        pub const packet_ping = struct {
            time: i64,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                try r.read_i64(&self.time);
            }
        };

        pub const packet_ping_start = struct {

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                
            }
        };

        pub const packet = struct {
            name: protocol_support.Todo,
            params: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.name);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                
            }
        };


    };
};pub const login = struct {
    pub const toClient = struct {
        pub const packet_compress = struct {
            threshold: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                try r.read_varint(&self.threshold);
            }
        };

        pub const packet_encryption_begin = struct {
            serverId: string,
            publicKey: protocol_support.Todo,
            verifyToken: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.serverId);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.publicKey);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.verifyToken);
            }
        };

        pub const packet_success = struct {
            uuid: protocol_support.UUID,
            username: string,
            properties: []struct {
                name: string,
                value: string,
                signature: protocol_support.Todo,

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    // parent_type null grandparent_type null
                    // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                    try protocol_support.todo(r, &self.name);
                    // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                    try protocol_support.todo(r, &self.value);
                    // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                    try protocol_support.todo(r, &self.signature);
                }
            },

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_UUID(&self.uuid);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.username);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.properties = allocator.alloc(@TypeOf(self.properties[0]), length_0);
                for (0..length_0) |i_0| {
                    // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                    // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } }
                    try protocol_support.todo(r, &self.properties[i_0].name);
                    // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } }
                    try protocol_support.todo(r, &self.properties[i_0].value);
                    // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } }
                    try protocol_support.todo(r, &self.properties[i_0].signature);
                }
            }
        };

        pub const packet_disconnect = struct {
            reason: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.reason);
            }
        };

        pub const packet_login_plugin_request = struct {
            messageId: i32,
            channel: string,
            data: protocol_support.restBuffer,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.messageId);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.channel);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_restBuffer(&self.data);
            }
        };

        pub const packet = struct {
            name: protocol_support.Todo,
            params: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.name);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                
            }
        };


    };
    pub const toServer = struct {
        pub const packet_encryption_begin = struct {
            sharedSecret: protocol_support.Todo,
            verifyToken: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.sharedSecret);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.verifyToken);
            }
        };

        pub const packet_login_start = struct {
            username: string,
            playerUUID: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.username);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.playerUUID);
            }
        };

        pub const packet_login_plugin_response = struct {
            messageId: i32,
            data: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.messageId);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.data);
            }
        };

        pub const packet = struct {
            name: protocol_support.Todo,
            params: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.name);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                
            }
        };


    };
};pub const play = struct {
    pub const toClient = struct {
        pub const packet_update_time = struct {
            age: i64,
            time: i64,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i64(&self.age);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i64(&self.time);
            }
        };

        pub const packet_hide_message = struct {
            id: i32,
            signature: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.id);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                
            }
        };

        pub const packet_set_title_time = struct {
            fadeIn: i32,
            stay: i32,
            fadeOut: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i32(&self.fadeIn);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i32(&self.stay);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i32(&self.fadeOut);
            }
        };

        pub const packet_camera = struct {
            cameraId: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                try r.read_varint(&self.cameraId);
            }
        };

        pub const packet_entity_sound_effect = struct {
            soundId: i32,
            soundEvent: protocol_support.Todo,
            soundCategory: soundSource,
            entityId: i32,
            volume: f32,
            pitch: f32,
            seed: i64,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.soundId);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.soundCategory);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.entityId);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f32(&self.volume);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f32(&self.pitch);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i64(&self.seed);
            }
        };

        pub const packet_world_event = struct {
            effectId: i32,
            location: position,
            data: i32,
            global: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i32(&self.effectId);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.location);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i32(&self.data);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_bool(&self.global);
            }
        };

        pub const packet_entity_look = struct {
            entityId: i32,
            yaw: i8,
            pitch: i8,
            onGround: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.entityId);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i8(&self.yaw);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i8(&self.pitch);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_bool(&self.onGround);
            }
        };

        pub const packet_death_combat_event = struct {
            playerId: i32,
            message: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.playerId);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.message);
            }
        };

        pub const packet_position = struct {
            x: f64,
            y: f64,
            z: f64,
            yaw: f32,
            pitch: f32,
            flags: i8,
            teleportId: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f64(&self.x);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f64(&self.y);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f64(&self.z);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f32(&self.yaw);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f32(&self.pitch);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i8(&self.flags);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.teleportId);
            }
        };

        pub const packet_stop_sound = struct {
            flags: i8,
            source: protocol_support.Todo,
            sound: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i8(&self.flags);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                
            }
        };

        pub const packet_simulation_distance = struct {
            distance: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                try r.read_varint(&self.distance);
            }
        };

        pub const packet_custom_payload = struct {
            channel: string,
            data: protocol_support.restBuffer,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.channel);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_restBuffer(&self.data);
            }
        };

        pub const packet_vehicle_move = struct {
            x: f64,
            y: f64,
            z: f64,
            yaw: f32,
            pitch: f32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f64(&self.x);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f64(&self.y);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f64(&self.z);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f32(&self.yaw);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f32(&self.pitch);
            }
        };

        pub const packet_set_title_text = struct {
            text: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.text);
            }
        };

        pub const packet_spawn_position = struct {
            location: position,
            angle: f32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.location);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f32(&self.angle);
            }
        };

        pub const packet_craft_progress_bar = struct {
            windowId: u8,
            property: i16,
            value: i16,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_u8(&self.windowId);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i16(&self.property);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i16(&self.value);
            }
        };

        pub const packet_spawn_entity = struct {
            entityId: i32,
            objectUUID: protocol_support.UUID,
            type: i32,
            x: f64,
            y: f64,
            z: f64,
            pitch: i8,
            yaw: i8,
            headPitch: i8,
            objectData: i32,
            velocityX: i16,
            velocityY: i16,
            velocityZ: i16,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.entityId);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_UUID(&self.objectUUID);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.type);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f64(&self.x);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f64(&self.y);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f64(&self.z);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i8(&self.pitch);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i8(&self.yaw);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i8(&self.headPitch);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.objectData);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i16(&self.velocityX);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i16(&self.velocityY);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i16(&self.velocityZ);
            }
        };

        pub const packet_scoreboard_display_objective = struct {
            position: i8,
            name: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i8(&self.position);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... } } } } grandparent_type null
                try protocol_support.todo(r, &self.name);
            }
        };

        pub const packet_named_entity_spawn = struct {
            entityId: i32,
            playerUUID: protocol_support.UUID,
            x: f64,
            y: f64,
            z: f64,
            yaw: i8,
            pitch: i8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.entityId);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_UUID(&self.playerUUID);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f64(&self.x);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f64(&self.y);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f64(&self.z);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i8(&self.yaw);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_i8(&self.pitch);
            }
        };

        pub const packet_enter_combat_event = struct {

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                
            }
        };

        pub const packet_entity_destroy = struct {
            entityIds: []i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.entityIds = allocator.alloc(@TypeOf(self.entityIds[0]), length_0);
                for (0..length_0) |i_0| {
                    // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                    try r.read_varint(&self.entityIds[i_0]);
                }
            }
        };

        pub const packet_player_remove = struct {
            players: []protocol_support.UUID,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.players = allocator.alloc(@TypeOf(self.players[0]), length_0);
                for (0..length_0) |i_0| {
                    // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                    try r.read_UUID(&self.players[i_0]);
                }
            }
        };

        pub const packet_world_border_warning_reach = struct {
            warningBlocks: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... } } } } grandparent_type null
                try r.read_varint(&self.warningBlocks);
            }
        };

        pub const packet_update_health = struct {
            health: f32,
            food: i32,
            foodSaturation: f32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                // parent_type null grandparent_type null
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f32(&self.health);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_varint(&self.food);
                // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                try r.read_f32(&self.foodSaturation);
            }
        };

        pub const packet_player_info = struct {
            action: protocol_support.Todo,
            data: []struct {
                uuid: protocol_support.UUID,
                player: protocol_support.Todo,
                chatSession: protocol_support.Todo,
                gamemode: protocol_support.Todo,
                listed: protocol_support.Todo,
                latency: protocol_support.Todo,
                displayName: protocol_support.Todo,

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    // parent_type null grandparent_type null
                    // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                    try r.read_UUID(&self.uuid);
                    // parent_type .{ .container = .{ .fields = { .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... }, .{ ... } } } } grandparent_type null
                    