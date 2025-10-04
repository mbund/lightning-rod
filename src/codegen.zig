const std = @import("std");
const protocol_support = @import("protocol_support.zig");

pub const previousMessages = []struct {
    id: i32,
    signature: protocol_support.Todo,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        try r.read_varint(&self.id);
        try protocol_support.todo(r, &self.signature);
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
        try protocol_support.todo(r, &self.anon);
        try r.read_i16(&self.y);
        try r.read_varint(&self.type);
        try r.read_optionalNbt(&self.nbtData);
    }
};

pub const entityMetadataItem = protocol_support.Todo;

pub const entityMetadata = protocol_support.Todo;

pub const vec3f = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        try r.read_f32(&self.x);
        try r.read_f32(&self.y);
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
        try r.read_i32(&self.z);
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
        try protocol_support.todo(r, &self.tagName);
        var length_0: i32 = undefined;
        try r.read_varint(&length_0);
        self.entries = allocator.alloc(@TypeOf(self.entries[0]), length_0);
        for (0..length_0) |i_0| {
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
        try r.read_f32(&self.x);
        try r.read_f32(&self.y);
        try r.read_f32(&self.z);
        try r.read_f32(&self.w);
    }
};

pub const particleData = protocol_support.Todo;

pub const minecraft_simple_recipe_format = struct {
    category: i32,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        try r.read_varint(&self.category);
    }
};

pub const position = protocol_support.Todo;

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
        try protocol_support.todo(r, &self.group);
        try r.read_varint(&self.category);
        var length_0: i32 = undefined;
        try r.read_varint(&length_0);
        self.ingredient = allocator.alloc(@TypeOf(self.ingredient[0]), length_0);
        for (0..length_0) |i_0| {
            try self.ingredient[i_0].read(r, allocator);
        }
        try self.result.read(r, allocator);
        try r.read_f32(&self.experience);
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
        try r.read_bool(&self.present);
        try protocol_support.todo(r, &self.anon);
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
        try r.read_varint(&self.particleId);
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
        try protocol_support.todo(r, &self.flags);
        var length_0: i32 = undefined;
        try r.read_varint(&length_0);
        self.children = allocator.alloc(@TypeOf(self.children[0]), length_0);
        for (0..length_0) |i_0| {
            try r.read_varint(&self.children[i_0]);
        }
        try protocol_support.todo(r, &self.redirectNode);
        try protocol_support.todo(r, &self.extraNodeData);
    }
};

pub const ItemSoundEvent = struct {
    soundName: string,
    fixedRange: protocol_support.Todo,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        try protocol_support.todo(r, &self.soundName);
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
            try protocol_support.todo(r, &self.name);
            try protocol_support.todo(r, &self.value);
            try protocol_support.todo(r, &self.signature);
        }
    },

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        protocol_support.maybe_unused(r);
        protocol_support.maybe_unused(self);
        try protocol_support.todo(r, &self.name);
        var length_0: i32 = undefined;
        try r.read_varint(&length_0);
        self.properties = allocator.alloc(@TypeOf(self.properties[0]), length_0);
        for (0..length_0) |i_0| {
            try protocol_support.todo(r, &self.properties[i_0].name);
            try protocol_support.todo(r, &self.properties[i_0].value);
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
        try r.read_f64(&self.x);
        try r.read_f64(&self.y);
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
                try protocol_support.todo(r, &self.name);
                try protocol_support.todo(r, &self.params);
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
                try r.read_varint(&self.protocolVersion);
                try protocol_support.todo(r, &self.serverHost);
                try r.read_u16(&self.serverPort);
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
                try protocol_support.todo(r, &self.name);
                try protocol_support.todo(r, &self.params);
            }
        };

        pub const packet_legacy_server_list_ping = struct {
            payload: u8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
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
                try protocol_support.todo(r, &self.name);
                try protocol_support.todo(r, &self.params);
            }
        };

        pub const packet_server_info = struct {
            response: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
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
                try r.read_i64(&self.time);
            }
        };

        pub const packet_ping_start = struct {

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                
            }
        };

        pub const packet = struct {
            name: protocol_support.Todo,
            params: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.name);
                try protocol_support.todo(r, &self.params);
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
                try protocol_support.todo(r, &self.serverId);
                try protocol_support.todo(r, &self.publicKey);
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
                    try protocol_support.todo(r, &self.name);
                    try protocol_support.todo(r, &self.value);
                    try protocol_support.todo(r, &self.signature);
                }
            },

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_UUID(&self.uuid);
                try protocol_support.todo(r, &self.username);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.properties = allocator.alloc(@TypeOf(self.properties[0]), length_0);
                for (0..length_0) |i_0| {
                    try protocol_support.todo(r, &self.properties[i_0].name);
                    try protocol_support.todo(r, &self.properties[i_0].value);
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
                try r.read_varint(&self.messageId);
                try protocol_support.todo(r, &self.channel);
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
                try protocol_support.todo(r, &self.name);
                try protocol_support.todo(r, &self.params);
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
                try protocol_support.todo(r, &self.sharedSecret);
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
                try protocol_support.todo(r, &self.username);
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
                try r.read_varint(&self.messageId);
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
                try protocol_support.todo(r, &self.name);
                try protocol_support.todo(r, &self.params);
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
                try r.read_i64(&self.age);
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
                try r.read_varint(&self.id);
                try protocol_support.todo(r, &self.signature);
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
                try r.read_i32(&self.fadeIn);
                try r.read_i32(&self.stay);
                try r.read_i32(&self.fadeOut);
            }
        };

        pub const packet_camera = struct {
            cameraId: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
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
                try r.read_varint(&self.soundId);
                try protocol_support.todo(r, &self.soundEvent);
                try protocol_support.todo(r, &self.soundCategory);
                try r.read_varint(&self.entityId);
                try r.read_f32(&self.volume);
                try r.read_f32(&self.pitch);
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
                try r.read_i32(&self.effectId);
                try protocol_support.todo(r, &self.location);
                try r.read_i32(&self.data);
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
                try r.read_varint(&self.entityId);
                try r.read_i8(&self.yaw);
                try r.read_i8(&self.pitch);
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
                try r.read_varint(&self.playerId);
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
                try r.read_f64(&self.x);
                try r.read_f64(&self.y);
                try r.read_f64(&self.z);
                try r.read_f32(&self.yaw);
                try r.read_f32(&self.pitch);
                try r.read_i8(&self.flags);
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
                try r.read_i8(&self.flags);
                try protocol_support.todo(r, &self.source);
                try protocol_support.todo(r, &self.sound);
            }
        };

        pub const packet_simulation_distance = struct {
            distance: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
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
                try protocol_support.todo(r, &self.channel);
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
                try r.read_f64(&self.x);
                try r.read_f64(&self.y);
                try r.read_f64(&self.z);
                try r.read_f32(&self.yaw);
                try r.read_f32(&self.pitch);
            }
        };

        pub const packet_set_title_text = struct {
            text: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
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
                try protocol_support.todo(r, &self.location);
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
                try r.read_u8(&self.windowId);
                try r.read_i16(&self.property);
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
                try r.read_varint(&self.entityId);
                try r.read_UUID(&self.objectUUID);
                try r.read_varint(&self.type);
                try r.read_f64(&self.x);
                try r.read_f64(&self.y);
                try r.read_f64(&self.z);
                try r.read_i8(&self.pitch);
                try r.read_i8(&self.yaw);
                try r.read_i8(&self.headPitch);
                try r.read_varint(&self.objectData);
                try r.read_i16(&self.velocityX);
                try r.read_i16(&self.velocityY);
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
                try r.read_i8(&self.position);
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
                try r.read_varint(&self.entityId);
                try r.read_UUID(&self.playerUUID);
                try r.read_f64(&self.x);
                try r.read_f64(&self.y);
                try r.read_f64(&self.z);
                try r.read_i8(&self.yaw);
                try r.read_i8(&self.pitch);
            }
        };

        pub const packet_enter_combat_event = struct {

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                
            }
        };

        pub const packet_entity_destroy = struct {
            entityIds: []i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.entityIds = allocator.alloc(@TypeOf(self.entityIds[0]), length_0);
                for (0..length_0) |i_0| {
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
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.players = allocator.alloc(@TypeOf(self.players[0]), length_0);
                for (0..length_0) |i_0| {
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
                try r.read_f32(&self.health);
                try r.read_varint(&self.food);
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
                    try r.read_UUID(&self.uuid);
                    try protocol_support.todo(r, &self.player);
                    try protocol_support.todo(r, &self.chatSession);
                    try protocol_support.todo(r, &self.gamemode);
                    try protocol_support.todo(r, &self.listed);
                    try protocol_support.todo(r, &self.latency);
                    try protocol_support.todo(r, &self.displayName);
                }
            },

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.action);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.data = allocator.alloc(@TypeOf(self.data[0]), length_0);
                for (0..length_0) |i_0| {
                    try r.read_UUID(&self.data[i_0].uuid);
                    try protocol_support.todo(r, &self.data[i_0].player);
                    try protocol_support.todo(r, &self.data[i_0].chatSession);
                    try protocol_support.todo(r, &self.data[i_0].gamemode);
                    try protocol_support.todo(r, &self.data[i_0].listed);
                    try protocol_support.todo(r, &self.data[i_0].latency);
                    try protocol_support.todo(r, &self.data[i_0].displayName);
                }
            }
        };

        pub const packet_world_border_warning_delay = struct {
            warningTime: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.warningTime);
            }
        };

        pub const packet_update_view_position = struct {
            chunkX: i32,
            chunkZ: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.chunkX);
                try r.read_varint(&self.chunkZ);
            }
        };

        pub const packet_statistics = struct {
            entries: []struct {
                categoryId: i32,
                statisticId: i32,
                value: i32,

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    try r.read_varint(&self.categoryId);
                    try r.read_varint(&self.statisticId);
                    try r.read_varint(&self.value);
                }
            },

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.entries = allocator.alloc(@TypeOf(self.entries[0]), length_0);
                for (0..length_0) |i_0| {
                    try r.read_varint(&self.entries[i_0].categoryId);
                    try r.read_varint(&self.entries[i_0].statisticId);
                    try r.read_varint(&self.entries[i_0].value);
                }
            }
        };

        pub const packet_server_data = struct {
            motd: string,
            iconBytes: protocol_support.Todo,
            enforcesSecureChat: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.motd);
                try protocol_support.todo(r, &self.iconBytes);
                try r.read_bool(&self.enforcesSecureChat);
            }
        };

        pub const packet_open_horse_window = struct {
            windowId: u8,
            nbSlots: i32,
            entityId: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_u8(&self.windowId);
                try r.read_varint(&self.nbSlots);
                try r.read_i32(&self.entityId);
            }
        };

        pub const packet_initialize_world_border = struct {
            x: f64,
            z: f64,
            oldDiameter: f64,
            newDiameter: f64,
            speed: i32,
            portalTeleportBoundary: i32,
            warningBlocks: i32,
            warningTime: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_f64(&self.x);
                try r.read_f64(&self.z);
                try r.read_f64(&self.oldDiameter);
                try r.read_f64(&self.newDiameter);
                try r.read_varint(&self.speed);
                try r.read_varint(&self.portalTeleportBoundary);
                try r.read_varint(&self.warningBlocks);
                try r.read_varint(&self.warningTime);
            }
        };

        pub const packet_block_action = struct {
            location: position,
            byte1: u8,
            byte2: u8,
            blockId: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.location);
                try r.read_u8(&self.byte1);
                try r.read_u8(&self.byte2);
                try r.read_varint(&self.blockId);
            }
        };

        pub const packet_entity_status = struct {
            entityId: i32,
            entityStatus: i8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i32(&self.entityId);
                try r.read_i8(&self.entityStatus);
            }
        };

        pub const packet_action_bar = struct {
            text: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.text);
            }
        };

        pub const packet_world_particles = struct {
            particleId: i32,
            longDistance: bool,
            x: f64,
            y: f64,
            z: f64,
            offsetX: f32,
            offsetY: f32,
            offsetZ: f32,
            particleData: f32,
            particles: i32,
            data: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.particleId);
                try r.read_bool(&self.longDistance);
                try r.read_f64(&self.x);
                try r.read_f64(&self.y);
                try r.read_f64(&self.z);
                try r.read_f32(&self.offsetX);
                try r.read_f32(&self.offsetY);
                try r.read_f32(&self.offsetZ);
                try r.read_f32(&self.particleData);
                try r.read_i32(&self.particles);
                try protocol_support.todo(r, &self.data);
            }
        };

        pub const packet_experience = struct {
            experienceBar: f32,
            level: i32,
            totalExperience: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_f32(&self.experienceBar);
                try r.read_varint(&self.level);
                try r.read_varint(&self.totalExperience);
            }
        };

        pub const packet_chunk_biomes = struct {
            biomes: []struct {
                position: packedChunkPos,
                data: protocol_support.Todo,

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    try self.position.read(r, allocator);
                    try protocol_support.todo(r, &self.data);
                }
            },

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.biomes = allocator.alloc(@TypeOf(self.biomes[0]), length_0);
                for (0..length_0) |i_0| {
                    try self.biomes[i_0].position.read(r, allocator);
                    try protocol_support.todo(r, &self.biomes[i_0].data);
                }
            }
        };

        pub const packet_damage_event = struct {
            entityId: i32,
            sourceTypeId: i32,
            sourceCauseId: i32,
            sourceDirectId: i32,
            sourcePosition: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try r.read_varint(&self.sourceTypeId);
                try r.read_varint(&self.sourceCauseId);
                try r.read_varint(&self.sourceDirectId);
                try protocol_support.todo(r, &self.sourcePosition);
            }
        };

        pub const packet_feature_flags = struct {
            features: []string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.features = allocator.alloc(@TypeOf(self.features[0]), length_0);
                for (0..length_0) |i_0| {
                    try protocol_support.todo(r, &self.features[i_0]);
                }
            }
        };

        pub const packet_set_cooldown = struct {
            itemID: i32,
            cooldownTicks: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.itemID);
                try r.read_varint(&self.cooldownTicks);
            }
        };

        pub const packet_world_border_center = struct {
            x: f64,
            z: f64,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_f64(&self.x);
                try r.read_f64(&self.z);
            }
        };

        pub const packet_sound_effect = struct {
            sound: ItemSoundHolder,
            soundCategory: soundSource,
            x: i32,
            y: i32,
            z: i32,
            volume: f32,
            pitch: f32,
            seed: i64,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.sound);
                try protocol_support.todo(r, &self.soundCategory);
                try r.read_i32(&self.x);
                try r.read_i32(&self.y);
                try r.read_i32(&self.z);
                try r.read_f32(&self.volume);
                try r.read_f32(&self.pitch);
                try r.read_i64(&self.seed);
            }
        };

        pub const packet_system_chat = struct {
            content: string,
            isActionBar: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.content);
                try r.read_bool(&self.isActionBar);
            }
        };

        pub const packet_unload_chunk = struct {
            chunkX: i32,
            chunkZ: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i32(&self.chunkX);
                try r.read_i32(&self.chunkZ);
            }
        };

        pub const packet_scoreboard_score = struct {
            itemName: string,
            action: i32,
            scoreName: string,
            value: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.itemName);
                try r.read_varint(&self.action);
                try protocol_support.todo(r, &self.scoreName);
                try protocol_support.todo(r, &self.value);
            }
        };

        pub const packet_entity_effect = struct {
            entityId: i32,
            effectId: i32,
            amplifier: i8,
            duration: i32,
            hideParticles: i8,
            factorCodec: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try r.read_varint(&self.effectId);
                try r.read_i8(&self.amplifier);
                try r.read_varint(&self.duration);
                try r.read_i8(&self.hideParticles);
                try protocol_support.todo(r, &self.factorCodec);
            }
        };

        pub const packet_respawn = struct {
            dimension: string,
            worldName: string,
            hashedSeed: i64,
            gamemode: i8,
            previousGamemode: u8,
            isDebug: bool,
            isFlat: bool,
            copyMetadata: bool,
            death: protocol_support.Todo,
            portalCooldown: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.dimension);
                try protocol_support.todo(r, &self.worldName);
                try r.read_i64(&self.hashedSeed);
                try r.read_i8(&self.gamemode);
                try r.read_u8(&self.previousGamemode);
                try r.read_bool(&self.isDebug);
                try r.read_bool(&self.isFlat);
                try r.read_bool(&self.copyMetadata);
                try protocol_support.todo(r, &self.death);
                try r.read_varint(&self.portalCooldown);
            }
        };

        pub const packet_ping = struct {
            id: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i32(&self.id);
            }
        };

        pub const packet_craft_recipe_response = struct {
            windowId: i8,
            recipe: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i8(&self.windowId);
                try protocol_support.todo(r, &self.recipe);
            }
        };

        pub const packet_entity_metadata = struct {
            entityId: i32,
            metadata: entityMetadata,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try protocol_support.todo(r, &self.metadata);
            }
        };

        pub const packet_update_view_distance = struct {
            viewDistance: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.viewDistance);
            }
        };

        pub const packet = struct {
            name: protocol_support.Todo,
            params: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.name);
                try protocol_support.todo(r, &self.params);
            }
        };

        pub const packet_set_passengers = struct {
            entityId: i32,
            passengers: []i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.passengers = allocator.alloc(@TypeOf(self.passengers[0]), length_0);
                for (0..length_0) |i_0| {
                    try r.read_varint(&self.passengers[i_0]);
                }
            }
        };

        pub const packet_held_item_slot = struct {
            slot: i8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i8(&self.slot);
            }
        };

        pub const packet_entity_move_look = struct {
            entityId: i32,
            dX: i16,
            dY: i16,
            dZ: i16,
            yaw: i8,
            pitch: i8,
            onGround: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try r.read_i16(&self.dX);
                try r.read_i16(&self.dY);
                try r.read_i16(&self.dZ);
                try r.read_i8(&self.yaw);
                try r.read_i8(&self.pitch);
                try r.read_bool(&self.onGround);
            }
        };

        pub const packet_entity_teleport = struct {
            entityId: i32,
            x: f64,
            y: f64,
            z: f64,
            yaw: i8,
            pitch: i8,
            onGround: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try r.read_f64(&self.x);
                try r.read_f64(&self.y);
                try r.read_f64(&self.z);
                try r.read_i8(&self.yaw);
                try r.read_i8(&self.pitch);
                try r.read_bool(&self.onGround);
            }
        };

        pub const packet_keep_alive = struct {
            keepAliveId: i64,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i64(&self.keepAliveId);
            }
        };

        pub const packet_map_chunk = struct {
            x: i32,
            z: i32,
            heightmaps: protocol_support.nbt,
            chunkData: protocol_support.Todo,
            blockEntities: []chunkBlockEntity,
            skyLightMask: []i64,
            blockLightMask: []i64,
            emptySkyLightMask: []i64,
            emptyBlockLightMask: []i64,
            skyLight: [][]u8,
            blockLight: [][]u8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i32(&self.x);
                try r.read_i32(&self.z);
                try r.read_nbt(&self.heightmaps);
                try protocol_support.todo(r, &self.chunkData);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.blockEntities = allocator.alloc(@TypeOf(self.blockEntities[0]), length_0);
                for (0..length_0) |i_0| {
                    try self.blockEntities[i_0].read(r, allocator);
                }
                var length_1: i32 = undefined;
                try r.read_varint(&length_1);
                self.skyLightMask = allocator.alloc(@TypeOf(self.skyLightMask[0]), length_1);
                for (0..length_1) |i_1| {
                    try r.read_i64(&self.skyLightMask[i_1]);
                }
                var length_2: i32 = undefined;
                try r.read_varint(&length_2);
                self.blockLightMask = allocator.alloc(@TypeOf(self.blockLightMask[0]), length_2);
                for (0..length_2) |i_2| {
                    try r.read_i64(&self.blockLightMask[i_2]);
                }
                var length_3: i32 = undefined;
                try r.read_varint(&length_3);
                self.emptySkyLightMask = allocator.alloc(@TypeOf(self.emptySkyLightMask[0]), length_3);
                for (0..length_3) |i_3| {
                    try r.read_i64(&self.emptySkyLightMask[i_3]);
                }
                var length_4: i32 = undefined;
                try r.read_varint(&length_4);
                self.emptyBlockLightMask = allocator.alloc(@TypeOf(self.emptyBlockLightMask[0]), length_4);
                for (0..length_4) |i_4| {
                    try r.read_i64(&self.emptyBlockLightMask[i_4]);
                }
                var length_5: i32 = undefined;
                try r.read_varint(&length_5);
                self.skyLight = allocator.alloc(@TypeOf(self.skyLight[0]), length_5);
                for (0..length_5) |i_5| {
                    var length_6: i32 = undefined;
                    try r.read_varint(&length_6);
                    self.skyLight[i_5] = allocator.alloc(@TypeOf(self.skyLight[i_5][0]), length_6);
                    for (0..length_6) |i_6| {
                        try r.read_u8(&self.skyLight[i_5][i_6]);
                    }
                }
                var length_7: i32 = undefined;
                try r.read_varint(&length_7);
                self.blockLight = allocator.alloc(@TypeOf(self.blockLight[0]), length_7);
                for (0..length_7) |i_7| {
                    var length_8: i32 = undefined;
                    try r.read_varint(&length_8);
                    self.blockLight[i_7] = allocator.alloc(@TypeOf(self.blockLight[i_7][0]), length_8);
                    for (0..length_8) |i_8| {
                        try r.read_u8(&self.blockLight[i_7][i_8]);
                    }
                }
            }
        };

        pub const packet_close_window = struct {
            windowId: u8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_u8(&self.windowId);
            }
        };

        pub const packet_hurt_animation = struct {
            entityId: i32,
            yaw: f32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try r.read_f32(&self.yaw);
            }
        };

        pub const packet_select_advancement_tab = struct {
            id: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.id);
            }
        };

        pub const packet_kick_disconnect = struct {
            reason: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.reason);
            }
        };

        pub const packet_block_break_animation = struct {
            entityId: i32,
            location: position,
            destroyStage: i8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try protocol_support.todo(r, &self.location);
                try r.read_i8(&self.destroyStage);
            }
        };

        pub const packet_tile_entity_data = struct {
            location: position,
            action: i32,
            nbtData: protocol_support.optionalNbt,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.location);
                try r.read_varint(&self.action);
                try r.read_optionalNbt(&self.nbtData);
            }
        };

        pub const packet_declare_recipes = struct {
            recipes: []struct {
                type: string,
                recipeId: string,
                data: protocol_support.Todo,

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    try protocol_support.todo(r, &self.type);
                    try protocol_support.todo(r, &self.recipeId);
                    try protocol_support.todo(r, &self.data);
                }
            },

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.recipes = allocator.alloc(@TypeOf(self.recipes[0]), length_0);
                for (0..length_0) |i_0| {
                    try protocol_support.todo(r, &self.recipes[i_0].type);
                    try protocol_support.todo(r, &self.recipes[i_0].recipeId);
                    try protocol_support.todo(r, &self.recipes[i_0].data);
                }
            }
        };

        pub const packet_teams = struct {
            team: string,
            mode: i8,
            name: protocol_support.Todo,
            friendlyFire: protocol_support.Todo,
            nameTagVisibility: protocol_support.Todo,
            collisionRule: protocol_support.Todo,
            formatting: protocol_support.Todo,
            prefix: protocol_support.Todo,
            suffix: protocol_support.Todo,
            players: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.team);
                try r.read_i8(&self.mode);
                try protocol_support.todo(r, &self.name);
                try protocol_support.todo(r, &self.friendlyFire);
                try protocol_support.todo(r, &self.nameTagVisibility);
                try protocol_support.todo(r, &self.collisionRule);
                try protocol_support.todo(r, &self.formatting);
                try protocol_support.todo(r, &self.prefix);
                try protocol_support.todo(r, &self.suffix);
                try protocol_support.todo(r, &self.players);
            }
        };

        pub const packet_set_slot = struct {
            windowId: i8,
            stateId: i32,
            slot: i16,
            item: slot,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i8(&self.windowId);
                try r.read_varint(&self.stateId);
                try r.read_i16(&self.slot);
                try self.item.read(r, allocator);
            }
        };

        pub const packet_trade_list = struct {
            windowId: i32,
            trades: []struct {
                inputItem1: slot,
                outputItem: slot,
                inputItem2: slot,
                tradeDisabled: bool,
                nbTradeUses: i32,
                maximumNbTradeUses: i32,
                xp: i32,
                specialPrice: i32,
                priceMultiplier: f32,
                demand: i32,

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    try self.inputItem1.read(r, allocator);
                    try self.outputItem.read(r, allocator);
                    try self.inputItem2.read(r, allocator);
                    try r.read_bool(&self.tradeDisabled);
                    try r.read_i32(&self.nbTradeUses);
                    try r.read_i32(&self.maximumNbTradeUses);
                    try r.read_i32(&self.xp);
                    try r.read_i32(&self.specialPrice);
                    try r.read_f32(&self.priceMultiplier);
                    try r.read_i32(&self.demand);
                }
            },
            villagerLevel: i32,
            experience: i32,
            isRegularVillager: bool,
            canRestock: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.windowId);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.trades = allocator.alloc(@TypeOf(self.trades[0]), length_0);
                for (0..length_0) |i_0| {
                    try self.trades[i_0].inputItem1.read(r, allocator);
                    try self.trades[i_0].outputItem.read(r, allocator);
                    try self.trades[i_0].inputItem2.read(r, allocator);
                    try r.read_bool(&self.trades[i_0].tradeDisabled);
                    try r.read_i32(&self.trades[i_0].nbTradeUses);
                    try r.read_i32(&self.trades[i_0].maximumNbTradeUses);
                    try r.read_i32(&self.trades[i_0].xp);
                    try r.read_i32(&self.trades[i_0].specialPrice);
                    try r.read_f32(&self.trades[i_0].priceMultiplier);
                    try r.read_i32(&self.trades[i_0].demand);
                }
                try r.read_varint(&self.villagerLevel);
                try r.read_varint(&self.experience);
                try r.read_bool(&self.isRegularVillager);
                try r.read_bool(&self.canRestock);
            }
        };

        pub const packet_scoreboard_objective = struct {
            name: string,
            action: i8,
            displayText: protocol_support.Todo,
            type: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.name);
                try r.read_i8(&self.action);
                try protocol_support.todo(r, &self.displayText);
                try protocol_support.todo(r, &self.type);
            }
        };

        pub const packet_playerlist_header = struct {
            header: string,
            footer: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.header);
                try protocol_support.todo(r, &self.footer);
            }
        };

        pub const packet_acknowledge_player_digging = struct {
            sequenceId: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.sequenceId);
            }
        };

        pub const packet_spawn_entity_experience_orb = struct {
            entityId: i32,
            x: f64,
            y: f64,
            z: f64,
            count: i16,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try r.read_f64(&self.x);
                try r.read_f64(&self.y);
                try r.read_f64(&self.z);
                try r.read_i16(&self.count);
            }
        };

        pub const packet_block_change = struct {
            location: position,
            type: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.location);
                try r.read_varint(&self.type);
            }
        };

        pub const packet_entity_equipment = struct {
            entityId: i32,
            equipments: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try protocol_support.todo(r, &self.equipments);
            }
        };

        pub const packet_chat_suggestions = struct {
            action: i32,
            entries: []string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.action);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.entries = allocator.alloc(@TypeOf(self.entries[0]), length_0);
                for (0..length_0) |i_0| {
                    try protocol_support.todo(r, &self.entries[i_0]);
                }
            }
        };

        pub const packet_collect = struct {
            collectedEntityId: i32,
            collectorEntityId: i32,
            pickupItemCount: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.collectedEntityId);
                try r.read_varint(&self.collectorEntityId);
                try r.read_varint(&self.pickupItemCount);
            }
        };

        pub const packet_unlock_recipes = struct {
            action: i32,
            craftingBookOpen: bool,
            filteringCraftable: bool,
            smeltingBookOpen: bool,
            filteringSmeltable: bool,
            blastFurnaceOpen: bool,
            filteringBlastFurnace: bool,
            smokerBookOpen: bool,
            filteringSmoker: bool,
            recipes1: []string,
            recipes2: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.action);
                try r.read_bool(&self.craftingBookOpen);
                try r.read_bool(&self.filteringCraftable);
                try r.read_bool(&self.smeltingBookOpen);
                try r.read_bool(&self.filteringSmeltable);
                try r.read_bool(&self.blastFurnaceOpen);
                try r.read_bool(&self.filteringBlastFurnace);
                try r.read_bool(&self.smokerBookOpen);
                try r.read_bool(&self.filteringSmoker);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.recipes1 = allocator.alloc(@TypeOf(self.recipes1[0]), length_0);
                for (0..length_0) |i_0| {
                    try protocol_support.todo(r, &self.recipes1[i_0]);
                }
                try protocol_support.todo(r, &self.recipes2);
            }
        };

        pub const packet_login = struct {
            entityId: i32,
            isHardcore: bool,
            gameMode: u8,
            previousGameMode: i8,
            worldNames: []string,
            dimensionCodec: protocol_support.nbt,
            worldType: string,
            worldName: string,
            hashedSeed: i64,
            maxPlayers: i32,
            viewDistance: i32,
            simulationDistance: i32,
            reducedDebugInfo: bool,
            enableRespawnScreen: bool,
            isDebug: bool,
            isFlat: bool,
            death: protocol_support.Todo,
            portalCooldown: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i32(&self.entityId);
                try r.read_bool(&self.isHardcore);
                try r.read_u8(&self.gameMode);
                try r.read_i8(&self.previousGameMode);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.worldNames = allocator.alloc(@TypeOf(self.worldNames[0]), length_0);
                for (0..length_0) |i_0| {
                    try protocol_support.todo(r, &self.worldNames[i_0]);
                }
                try r.read_nbt(&self.dimensionCodec);
                try protocol_support.todo(r, &self.worldType);
                try protocol_support.todo(r, &self.worldName);
                try r.read_i64(&self.hashedSeed);
                try r.read_varint(&self.maxPlayers);
                try r.read_varint(&self.viewDistance);
                try r.read_varint(&self.simulationDistance);
                try r.read_bool(&self.reducedDebugInfo);
                try r.read_bool(&self.enableRespawnScreen);
                try r.read_bool(&self.isDebug);
                try r.read_bool(&self.isFlat);
                try protocol_support.todo(r, &self.death);
                try r.read_varint(&self.portalCooldown);
            }
        };

        pub const packet_declare_commands = struct {
            nodes: []command_node,
            rootIndex: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.nodes = allocator.alloc(@TypeOf(self.nodes[0]), length_0);
                for (0..length_0) |i_0| {
                    try self.nodes[i_0].read(r, allocator);
                }
                try r.read_varint(&self.rootIndex);
            }
        };

        pub const packet_entity_velocity = struct {
            entityId: i32,
            velocityX: i16,
            velocityY: i16,
            velocityZ: i16,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try r.read_i16(&self.velocityX);
                try r.read_i16(&self.velocityY);
                try r.read_i16(&self.velocityZ);
            }
        };

        pub const packet_boss_bar = struct {
            entityUUID: protocol_support.UUID,
            action: i32,
            title: protocol_support.Todo,
            health: protocol_support.Todo,
            color: protocol_support.Todo,
            dividers: protocol_support.Todo,
            flags: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_UUID(&self.entityUUID);
                try r.read_varint(&self.action);
                try protocol_support.todo(r, &self.title);
                try protocol_support.todo(r, &self.health);
                try protocol_support.todo(r, &self.color);
                try protocol_support.todo(r, &self.dividers);
                try protocol_support.todo(r, &self.flags);
            }
        };

        pub const packet_open_sign_entity = struct {
            location: position,
            isFrontText: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.location);
                try r.read_bool(&self.isFrontText);
            }
        };

        pub const packet_profileless_chat = struct {
            message: string,
            type: i32,
            name: string,
            target: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.message);
                try r.read_varint(&self.type);
                try protocol_support.todo(r, &self.name);
                try protocol_support.todo(r, &self.target);
            }
        };

        pub const packet_window_items = struct {
            windowId: u8,
            stateId: i32,
            items: []slot,
            carriedItem: slot,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_u8(&self.windowId);
                try r.read_varint(&self.stateId);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.items = allocator.alloc(@TypeOf(self.items[0]), length_0);
                for (0..length_0) |i_0| {
                    try self.items[i_0].read(r, allocator);
                }
                try self.carriedItem.read(r, allocator);
            }
        };

        pub const packet_game_state_change = struct {
            reason: u8,
            gameMode: f32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_u8(&self.reason);
                try r.read_f32(&self.gameMode);
            }
        };

        pub const packet_map = struct {
            itemDamage: i32,
            scale: i8,
            locked: bool,
            icons: protocol_support.Todo,
            columns: u8,
            rows: protocol_support.Todo,
            x: protocol_support.Todo,
            y: protocol_support.Todo,
            data: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.itemDamage);
                try r.read_i8(&self.scale);
                try r.read_bool(&self.locked);
                try protocol_support.todo(r, &self.icons);
                try r.read_u8(&self.columns);
                try protocol_support.todo(r, &self.rows);
                try protocol_support.todo(r, &self.x);
                try protocol_support.todo(r, &self.y);
                try protocol_support.todo(r, &self.data);
            }
        };

        pub const packet_multi_block_change = struct {
            chunkCoordinates: protocol_support.Todo,
            records: []i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.chunkCoordinates);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.records = allocator.alloc(@TypeOf(self.records[0]), length_0);
                for (0..length_0) |i_0| {
                    try r.read_varint(&self.records[i_0]);
                }
            }
        };

        pub const packet_remove_entity_effect = struct {
            entityId: i32,
            effectId: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try r.read_varint(&self.effectId);
            }
        };

        pub const packet_resource_pack_send = struct {
            url: string,
            hash: string,
            forced: bool,
            promptMessage: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.url);
                try protocol_support.todo(r, &self.hash);
                try r.read_bool(&self.forced);
                try protocol_support.todo(r, &self.promptMessage);
            }
        };

        pub const packet_tags = struct {
            tags: []struct {
                tagType: string,
                tags: tags,

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    try protocol_support.todo(r, &self.tagType);
                    var length_0: i32 = undefined;
                    try r.read_varint(&length_0);
                    self.tags = allocator.alloc(@TypeOf(self.tags[0]), length_0);
                    for (0..length_0) |i_0| {
                        try protocol_support.todo(r, &self.tags[i_0].tagName);
                        var length_1: i32 = undefined;
                        try r.read_varint(&length_1);
                        self.tags[i_0].entries = allocator.alloc(@TypeOf(self.tags[i_0].entries[0]), length_1);
                        for (0..length_1) |i_1| {
                            try r.read_varint(&self.tags[i_0].entries[i_1]);
                        }
                    }
                }
            },

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.tags = allocator.alloc(@TypeOf(self.tags[0]), length_0);
                for (0..length_0) |i_0| {
                    try protocol_support.todo(r, &self.tags[i_0].tagType);
                    var length_1: i32 = undefined;
                    try r.read_varint(&length_1);
                    self.tags[i_0].tags = allocator.alloc(@TypeOf(self.tags[i_0].tags[0]), length_1);
                    for (0..length_1) |i_1| {
                        try protocol_support.todo(r, &self.tags[i_0].tags[i_1].tagName);
                        var length_2: i32 = undefined;
                        try r.read_varint(&length_2);
                        self.tags[i_0].tags[i_1].entries = allocator.alloc(@TypeOf(self.tags[i_0].tags[i_1].entries[0]), length_2);
                        for (0..length_2) |i_2| {
                            try r.read_varint(&self.tags[i_0].tags[i_1].entries[i_2]);
                        }
                    }
                }
            }
        };

        pub const packet_open_book = struct {
            hand: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.hand);
            }
        };

        pub const packet_attach_entity = struct {
            entityId: i32,
            vehicleId: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i32(&self.entityId);
                try r.read_i32(&self.vehicleId);
            }
        };

        pub const packet_tab_complete = struct {
            transactionId: i32,
            start: i32,
            length: i32,
            matches: []struct {
                match: string,
                tooltip: protocol_support.Todo,

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    try protocol_support.todo(r, &self.match);
                    try protocol_support.todo(r, &self.tooltip);
                }
            },

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.transactionId);
                try r.read_varint(&self.start);
                try r.read_varint(&self.length);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.matches = allocator.alloc(@TypeOf(self.matches[0]), length_0);
                for (0..length_0) |i_0| {
                    try protocol_support.todo(r, &self.matches[i_0].match);
                    try protocol_support.todo(r, &self.matches[i_0].tooltip);
                }
            }
        };

        pub const packet_player_chat = struct {
            senderUuid: protocol_support.UUID,
            index: i32,
            signature: protocol_support.Todo,
            plainMessage: string,
            timestamp: i64,
            salt: i64,
            previousMessages: previousMessages,
            unsignedChatContent: protocol_support.Todo,
            filterType: i32,
            filterTypeMask: protocol_support.Todo,
            type: i32,
            networkName: string,
            networkTargetName: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_UUID(&self.senderUuid);
                try r.read_varint(&self.index);
                try protocol_support.todo(r, &self.signature);
                try protocol_support.todo(r, &self.plainMessage);
                try r.read_i64(&self.timestamp);
                try r.read_i64(&self.salt);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.previousMessages = allocator.alloc(@TypeOf(self.previousMessages[0]), length_0);
                for (0..length_0) |i_0| {
                    try r.read_varint(&self.previousMessages[i_0].id);
                    try protocol_support.todo(r, &self.previousMessages[i_0].signature);
                }
                try protocol_support.todo(r, &self.unsignedChatContent);
                try r.read_varint(&self.filterType);
                try protocol_support.todo(r, &self.filterTypeMask);
                try r.read_varint(&self.type);
                try protocol_support.todo(r, &self.networkName);
                try protocol_support.todo(r, &self.networkTargetName);
            }
        };

        pub const packet_end_combat_event = struct {
            duration: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.duration);
            }
        };

        pub const packet_nbt_query_response = struct {
            transactionId: i32,
            nbt: protocol_support.optionalNbt,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.transactionId);
                try r.read_optionalNbt(&self.nbt);
            }
        };

        pub const packet_world_border_size = struct {
            diameter: f64,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_f64(&self.diameter);
            }
        };

        pub const packet_update_light = struct {
            chunkX: i32,
            chunkZ: i32,
            skyLightMask: []i64,
            blockLightMask: []i64,
            emptySkyLightMask: []i64,
            emptyBlockLightMask: []i64,
            skyLight: [][]u8,
            blockLight: [][]u8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.chunkX);
                try r.read_varint(&self.chunkZ);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.skyLightMask = allocator.alloc(@TypeOf(self.skyLightMask[0]), length_0);
                for (0..length_0) |i_0| {
                    try r.read_i64(&self.skyLightMask[i_0]);
                }
                var length_1: i32 = undefined;
                try r.read_varint(&length_1);
                self.blockLightMask = allocator.alloc(@TypeOf(self.blockLightMask[0]), length_1);
                for (0..length_1) |i_1| {
                    try r.read_i64(&self.blockLightMask[i_1]);
                }
                var length_2: i32 = undefined;
                try r.read_varint(&length_2);
                self.emptySkyLightMask = allocator.alloc(@TypeOf(self.emptySkyLightMask[0]), length_2);
                for (0..length_2) |i_2| {
                    try r.read_i64(&self.emptySkyLightMask[i_2]);
                }
                var length_3: i32 = undefined;
                try r.read_varint(&length_3);
                self.emptyBlockLightMask = allocator.alloc(@TypeOf(self.emptyBlockLightMask[0]), length_3);
                for (0..length_3) |i_3| {
                    try r.read_i64(&self.emptyBlockLightMask[i_3]);
                }
                var length_4: i32 = undefined;
                try r.read_varint(&length_4);
                self.skyLight = allocator.alloc(@TypeOf(self.skyLight[0]), length_4);
                for (0..length_4) |i_4| {
                    var length_5: i32 = undefined;
                    try r.read_varint(&length_5);
                    self.skyLight[i_4] = allocator.alloc(@TypeOf(self.skyLight[i_4][0]), length_5);
                    for (0..length_5) |i_5| {
                        try r.read_u8(&self.skyLight[i_4][i_5]);
                    }
                }
                var length_6: i32 = undefined;
                try r.read_varint(&length_6);
                self.blockLight = allocator.alloc(@TypeOf(self.blockLight[0]), length_6);
                for (0..length_6) |i_6| {
                    var length_7: i32 = undefined;
                    try r.read_varint(&length_7);
                    self.blockLight[i_6] = allocator.alloc(@TypeOf(self.blockLight[i_6][0]), length_7);
                    for (0..length_7) |i_7| {
                        try r.read_u8(&self.blockLight[i_6][i_7]);
                    }
                }
            }
        };

        pub const packet_abilities = struct {
            flags: i8,
            flyingSpeed: f32,
            walkingSpeed: f32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i8(&self.flags);
                try r.read_f32(&self.flyingSpeed);
                try r.read_f32(&self.walkingSpeed);
            }
        };

        pub const packet_face_player = struct {
            feet_eyes: i32,
            x: f64,
            y: f64,
            z: f64,
            isEntity: bool,
            entityId: protocol_support.Todo,
            entity_feet_eyes: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.feet_eyes);
                try r.read_f64(&self.x);
                try r.read_f64(&self.y);
                try r.read_f64(&self.z);
                try r.read_bool(&self.isEntity);
                try protocol_support.todo(r, &self.entityId);
                try protocol_support.todo(r, &self.entity_feet_eyes);
            }
        };

        pub const packet_advancements = struct {
            reset: bool,
            advancementMapping: []struct {
                key: string,
                value: struct {
                    parentId: protocol_support.Todo,
                    displayData: protocol_support.Todo,
                    criteria: []struct {
                        key: string,
                        value: protocol_support.void,

                        pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                            protocol_support.maybe_unused(allocator);
                            protocol_support.maybe_unused(r);
                            protocol_support.maybe_unused(self);
                            try protocol_support.todo(r, &self.key);
                            try r.read_void(&self.value);
                        }
                    },
                    requirements: [][]string,
                    sendsTelemtryData: bool,

                    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                        protocol_support.maybe_unused(allocator);
                        protocol_support.maybe_unused(r);
                        protocol_support.maybe_unused(self);
                        try protocol_support.todo(r, &self.parentId);
                        try protocol_support.todo(r, &self.displayData);
                        var length_0: i32 = undefined;
                        try r.read_varint(&length_0);
                        self.criteria = allocator.alloc(@TypeOf(self.criteria[0]), length_0);
                        for (0..length_0) |i_0| {
                            try protocol_support.todo(r, &self.criteria[i_0].key);
                            try r.read_void(&self.criteria[i_0].value);
                        }
                        var length_1: i32 = undefined;
                        try r.read_varint(&length_1);
                        self.requirements = allocator.alloc(@TypeOf(self.requirements[0]), length_1);
                        for (0..length_1) |i_1| {
                            var length_2: i32 = undefined;
                            try r.read_varint(&length_2);
                            self.requirements[i_1] = allocator.alloc(@TypeOf(self.requirements[i_1][0]), length_2);
                            for (0..length_2) |i_2| {
                                try protocol_support.todo(r, &self.requirements[i_1][i_2]);
                            }
                        }
                        try r.read_bool(&self.sendsTelemtryData);
                    }
                },

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    try protocol_support.todo(r, &self.key);
                    try protocol_support.todo(r, &self.value.parentId);
                    try protocol_support.todo(r, &self.value.displayData);
                    var length_0: i32 = undefined;
                    try r.read_varint(&length_0);
                    self.value.criteria = allocator.alloc(@TypeOf(self.value.criteria[0]), length_0);
                    for (0..length_0) |i_0| {
                        try protocol_support.todo(r, &self.value.criteria[i_0].key);
                        try r.read_void(&self.value.criteria[i_0].value);
                    }
                    var length_1: i32 = undefined;
                    try r.read_varint(&length_1);
                    self.value.requirements = allocator.alloc(@TypeOf(self.value.requirements[0]), length_1);
                    for (0..length_1) |i_1| {
                        var length_2: i32 = undefined;
                        try r.read_varint(&length_2);
                        self.value.requirements[i_1] = allocator.alloc(@TypeOf(self.value.requirements[i_1][0]), length_2);
                        for (0..length_2) |i_2| {
                            try protocol_support.todo(r, &self.value.requirements[i_1][i_2]);
                        }
                    }
                    try r.read_bool(&self.value.sendsTelemtryData);
                }
            },
            identifiers: []string,
            progressMapping: []struct {
                key: string,
                value: []struct {
                    criterionIdentifier: string,
                    criterionProgress: protocol_support.Todo,

                    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                        protocol_support.maybe_unused(allocator);
                        protocol_support.maybe_unused(r);
                        protocol_support.maybe_unused(self);
                        try protocol_support.todo(r, &self.criterionIdentifier);
                        try protocol_support.todo(r, &self.criterionProgress);
                    }
                },

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    try protocol_support.todo(r, &self.key);
                    var length_0: i32 = undefined;
                    try r.read_varint(&length_0);
                    self.value = allocator.alloc(@TypeOf(self.value[0]), length_0);
                    for (0..length_0) |i_0| {
                        try protocol_support.todo(r, &self.value[i_0].criterionIdentifier);
                        try protocol_support.todo(r, &self.value[i_0].criterionProgress);
                    }
                }
            },

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_bool(&self.reset);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.advancementMapping = allocator.alloc(@TypeOf(self.advancementMapping[0]), length_0);
                for (0..length_0) |i_0| {
                    try protocol_support.todo(r, &self.advancementMapping[i_0].key);
                    try protocol_support.todo(r, &self.advancementMapping[i_0].value.parentId);
                    try protocol_support.todo(r, &self.advancementMapping[i_0].value.displayData);
                    var length_1: i32 = undefined;
                    try r.read_varint(&length_1);
                    self.advancementMapping[i_0].value.criteria = allocator.alloc(@TypeOf(self.advancementMapping[i_0].value.criteria[0]), length_1);
                    for (0..length_1) |i_1| {
                        try protocol_support.todo(r, &self.advancementMapping[i_0].value.criteria[i_1].key);
                        try r.read_void(&self.advancementMapping[i_0].value.criteria[i_1].value);
                    }
                    var length_2: i32 = undefined;
                    try r.read_varint(&length_2);
                    self.advancementMapping[i_0].value.requirements = allocator.alloc(@TypeOf(self.advancementMapping[i_0].value.requirements[0]), length_2);
                    for (0..length_2) |i_2| {
                        var length_3: i32 = undefined;
                        try r.read_varint(&length_3);
                        self.advancementMapping[i_0].value.requirements[i_2] = allocator.alloc(@TypeOf(self.advancementMapping[i_0].value.requirements[i_2][0]), length_3);
                        for (0..length_3) |i_3| {
                            try protocol_support.todo(r, &self.advancementMapping[i_0].value.requirements[i_2][i_3]);
                        }
                    }
                    try r.read_bool(&self.advancementMapping[i_0].value.sendsTelemtryData);
                }
                var length_4: i32 = undefined;
                try r.read_varint(&length_4);
                self.identifiers = allocator.alloc(@TypeOf(self.identifiers[0]), length_4);
                for (0..length_4) |i_4| {
                    try protocol_support.todo(r, &self.identifiers[i_4]);
                }
                var length_5: i32 = undefined;
                try r.read_varint(&length_5);
                self.progressMapping = allocator.alloc(@TypeOf(self.progressMapping[0]), length_5);
                for (0..length_5) |i_5| {
                    try protocol_support.todo(r, &self.progressMapping[i_5].key);
                    var length_6: i32 = undefined;
                    try r.read_varint(&length_6);
                    self.progressMapping[i_5].value = allocator.alloc(@TypeOf(self.progressMapping[i_5].value[0]), length_6);
                    for (0..length_6) |i_6| {
                        try protocol_support.todo(r, &self.progressMapping[i_5].value[i_6].criterionIdentifier);
                        try protocol_support.todo(r, &self.progressMapping[i_5].value[i_6].criterionProgress);
                    }
                }
            }
        };

        pub const packet_clear_titles = struct {
            reset: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_bool(&self.reset);
            }
        };

        pub const packet_difficulty = struct {
            difficulty: u8,
            difficultyLocked: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_u8(&self.difficulty);
                try r.read_bool(&self.difficultyLocked);
            }
        };

        pub const packet_explosion = struct {
            x: f64,
            y: f64,
            z: f64,
            radius: f32,
            affectedBlockOffsets: []struct {
                x: i8,
                y: i8,
                z: i8,

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    try r.read_i8(&self.x);
                    try r.read_i8(&self.y);
                    try r.read_i8(&self.z);
                }
            },
            playerMotionX: f32,
            playerMotionY: f32,
            playerMotionZ: f32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_f64(&self.x);
                try r.read_f64(&self.y);
                try r.read_f64(&self.z);
                try r.read_f32(&self.radius);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.affectedBlockOffsets = allocator.alloc(@TypeOf(self.affectedBlockOffsets[0]), length_0);
                for (0..length_0) |i_0| {
                    try r.read_i8(&self.affectedBlockOffsets[i_0].x);
                    try r.read_i8(&self.affectedBlockOffsets[i_0].y);
                    try r.read_i8(&self.affectedBlockOffsets[i_0].z);
                }
                try r.read_f32(&self.playerMotionX);
                try r.read_f32(&self.playerMotionY);
                try r.read_f32(&self.playerMotionZ);
            }
        };

        pub const packet_set_title_subtitle = struct {
            text: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.text);
            }
        };

        pub const packet_animation = struct {
            entityId: i32,
            animation: u8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try r.read_u8(&self.animation);
            }
        };

        pub const packet_open_window = struct {
            windowId: i32,
            inventoryType: i32,
            windowTitle: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.windowId);
                try r.read_varint(&self.inventoryType);
                try protocol_support.todo(r, &self.windowTitle);
            }
        };

        pub const packet_world_border_lerp_size = struct {
            oldDiameter: f64,
            newDiameter: f64,
            speed: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_f64(&self.oldDiameter);
                try r.read_f64(&self.newDiameter);
                try r.read_varint(&self.speed);
            }
        };

        pub const packet_entity_update_attributes = struct {
            entityId: i32,
            properties: []struct {
                name: string,
                value: f64,
                modifiers: []struct {
                    uuid: protocol_support.UUID,
                    amount: f64,
                    operation: i8,

                    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                        protocol_support.maybe_unused(allocator);
                        protocol_support.maybe_unused(r);
                        protocol_support.maybe_unused(self);
                        try r.read_UUID(&self.uuid);
                        try r.read_f64(&self.amount);
                        try r.read_i8(&self.operation);
                    }
                },

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    try protocol_support.todo(r, &self.name);
                    try r.read_f64(&self.value);
                    var length_0: i32 = undefined;
                    try r.read_varint(&length_0);
                    self.modifiers = allocator.alloc(@TypeOf(self.modifiers[0]), length_0);
                    for (0..length_0) |i_0| {
                        try r.read_UUID(&self.modifiers[i_0].uuid);
                        try r.read_f64(&self.modifiers[i_0].amount);
                        try r.read_i8(&self.modifiers[i_0].operation);
                    }
                }
            },

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.properties = allocator.alloc(@TypeOf(self.properties[0]), length_0);
                for (0..length_0) |i_0| {
                    try protocol_support.todo(r, &self.properties[i_0].name);
                    try r.read_f64(&self.properties[i_0].value);
                    var length_1: i32 = undefined;
                    try r.read_varint(&length_1);
                    self.properties[i_0].modifiers = allocator.alloc(@TypeOf(self.properties[i_0].modifiers[0]), length_1);
                    for (0..length_1) |i_1| {
                        try r.read_UUID(&self.properties[i_0].modifiers[i_1].uuid);
                        try r.read_f64(&self.properties[i_0].modifiers[i_1].amount);
                        try r.read_i8(&self.properties[i_0].modifiers[i_1].operation);
                    }
                }
            }
        };

        pub const packet_entity_head_rotation = struct {
            entityId: i32,
            headYaw: i8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try r.read_i8(&self.headYaw);
            }
        };

        pub const packet_rel_entity_move = struct {
            entityId: i32,
            dX: i16,
            dY: i16,
            dZ: i16,
            onGround: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try r.read_i16(&self.dX);
                try r.read_i16(&self.dY);
                try r.read_i16(&self.dZ);
                try r.read_bool(&self.onGround);
            }
        };


    };
    pub const toServer = struct {
        pub const packet_displayed_recipe = struct {
            recipeId: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.recipeId);
            }
        };

        pub const packet_keep_alive = struct {
            keepAliveId: i64,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i64(&self.keepAliveId);
            }
        };

        pub const packet_close_window = struct {
            windowId: u8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_u8(&self.windowId);
            }
        };

        pub const packet_set_creative_slot = struct {
            slot: i16,
            item: slot,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i16(&self.slot);
                try self.item.read(r, allocator);
            }
        };

        pub const packet_chat_command = struct {
            command: string,
            timestamp: i64,
            salt: i64,
            argumentSignatures: []struct {
                argumentName: string,
                signature: protocol_support.Todo,

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    try protocol_support.todo(r, &self.argumentName);
                    try protocol_support.todo(r, &self.signature);
                }
            },
            messageCount: i32,
            acknowledged: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.command);
                try r.read_i64(&self.timestamp);
                try r.read_i64(&self.salt);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.argumentSignatures = allocator.alloc(@TypeOf(self.argumentSignatures[0]), length_0);
                for (0..length_0) |i_0| {
                    try protocol_support.todo(r, &self.argumentSignatures[i_0].argumentName);
                    try protocol_support.todo(r, &self.argumentSignatures[i_0].signature);
                }
                try r.read_varint(&self.messageCount);
                try protocol_support.todo(r, &self.acknowledged);
            }
        };

        pub const packet_look = struct {
            yaw: f32,
            pitch: f32,
            onGround: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_f32(&self.yaw);
                try r.read_f32(&self.pitch);
                try r.read_bool(&self.onGround);
            }
        };

        pub const packet_update_structure_block = struct {
            location: position,
            action: i32,
            mode: i32,
            name: string,
            offset_x: i8,
            offset_y: i8,
            offset_z: i8,
            size_x: i8,
            size_y: i8,
            size_z: i8,
            mirror: i32,
            rotation: i32,
            metadata: string,
            integrity: f32,
            seed: i32,
            flags: u8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.location);
                try r.read_varint(&self.action);
                try r.read_varint(&self.mode);
                try protocol_support.todo(r, &self.name);
                try r.read_i8(&self.offset_x);
                try r.read_i8(&self.offset_y);
                try r.read_i8(&self.offset_z);
                try r.read_i8(&self.size_x);
                try r.read_i8(&self.size_y);
                try r.read_i8(&self.size_z);
                try r.read_varint(&self.mirror);
                try r.read_varint(&self.rotation);
                try protocol_support.todo(r, &self.metadata);
                try r.read_f32(&self.integrity);
                try r.read_varint(&self.seed);
                try r.read_u8(&self.flags);
            }
        };

        pub const packet_client_command = struct {
            actionId: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.actionId);
            }
        };

        pub const packet_pong = struct {
            id: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i32(&self.id);
            }
        };

        pub const packet_use_entity = struct {
            target: i32,
            mouse: i32,
            x: protocol_support.Todo,
            y: protocol_support.Todo,
            z: protocol_support.Todo,
            hand: protocol_support.Todo,
            sneaking: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.target);
                try r.read_varint(&self.mouse);
                try protocol_support.todo(r, &self.x);
                try protocol_support.todo(r, &self.y);
                try protocol_support.todo(r, &self.z);
                try protocol_support.todo(r, &self.hand);
                try r.read_bool(&self.sneaking);
            }
        };

        pub const packet_position = struct {
            x: f64,
            y: f64,
            z: f64,
            onGround: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_f64(&self.x);
                try r.read_f64(&self.y);
                try r.read_f64(&self.z);
                try r.read_bool(&self.onGround);
            }
        };

        pub const packet_recipe_book = struct {
            bookId: i32,
            bookOpen: bool,
            filterActive: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.bookId);
                try r.read_bool(&self.bookOpen);
                try r.read_bool(&self.filterActive);
            }
        };

        pub const packet_set_beacon_effect = struct {
            primary_effect: protocol_support.Todo,
            secondary_effect: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.primary_effect);
                try protocol_support.todo(r, &self.secondary_effect);
            }
        };

        pub const packet_name_item = struct {
            name: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.name);
            }
        };

        pub const packet_custom_payload = struct {
            channel: string,
            data: protocol_support.restBuffer,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.channel);
                try r.read_restBuffer(&self.data);
            }
        };

        pub const packet_lock_difficulty = struct {
            locked: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_bool(&self.locked);
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
                try r.read_f64(&self.x);
                try r.read_f64(&self.y);
                try r.read_f64(&self.z);
                try r.read_f32(&self.yaw);
                try r.read_f32(&self.pitch);
            }
        };

        pub const packet_flying = struct {
            onGround: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_bool(&self.onGround);
            }
        };

        pub const packet_settings = struct {
            locale: string,
            viewDistance: i8,
            chatFlags: i32,
            chatColors: bool,
            skinParts: u8,
            mainHand: i32,
            enableTextFiltering: bool,
            enableServerListing: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.locale);
                try r.read_i8(&self.viewDistance);
                try r.read_varint(&self.chatFlags);
                try r.read_bool(&self.chatColors);
                try r.read_u8(&self.skinParts);
                try r.read_varint(&self.mainHand);
                try r.read_bool(&self.enableTextFiltering);
                try r.read_bool(&self.enableServerListing);
            }
        };

        pub const packet_select_trade = struct {
            slot: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.slot);
            }
        };

        pub const packet_update_command_block = struct {
            location: position,
            command: string,
            mode: i32,
            flags: u8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.location);
                try protocol_support.todo(r, &self.command);
                try r.read_varint(&self.mode);
                try r.read_u8(&self.flags);
            }
        };

        pub const packet_update_command_block_minecart = struct {
            entityId: i32,
            command: string,
            track_output: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try protocol_support.todo(r, &self.command);
                try r.read_bool(&self.track_output);
            }
        };

        pub const packet_set_difficulty = struct {
            newDifficulty: u8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_u8(&self.newDifficulty);
            }
        };

        pub const packet_resource_pack_receive = struct {
            result: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.result);
            }
        };

        pub const packet_query_block_nbt = struct {
            transactionId: i32,
            location: position,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.transactionId);
                try protocol_support.todo(r, &self.location);
            }
        };

        pub const packet_advancement_tab = struct {
            action: i32,
            tabId: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.action);
                try protocol_support.todo(r, &self.tabId);
            }
        };

        pub const packet_entity_action = struct {
            entityId: i32,
            actionId: i32,
            jumpBoost: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.entityId);
                try r.read_varint(&self.actionId);
                try r.read_varint(&self.jumpBoost);
            }
        };

        pub const packet_block_place = struct {
            hand: i32,
            location: position,
            direction: i32,
            cursorX: f32,
            cursorY: f32,
            cursorZ: f32,
            insideBlock: bool,
            sequence: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.hand);
                try protocol_support.todo(r, &self.location);
                try r.read_varint(&self.direction);
                try r.read_f32(&self.cursorX);
                try r.read_f32(&self.cursorY);
                try r.read_f32(&self.cursorZ);
                try r.read_bool(&self.insideBlock);
                try r.read_varint(&self.sequence);
            }
        };

        pub const packet_window_click = struct {
            windowId: u8,
            stateId: i32,
            slot: i16,
            mouseButton: i8,
            mode: i32,
            changedSlots: []struct {
                location: i16,
                item: slot,

                pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                    protocol_support.maybe_unused(allocator);
                    protocol_support.maybe_unused(r);
                    protocol_support.maybe_unused(self);
                    try r.read_i16(&self.location);
                    try self.item.read(r, allocator);
                }
            },
            cursorItem: slot,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_u8(&self.windowId);
                try r.read_varint(&self.stateId);
                try r.read_i16(&self.slot);
                try r.read_i8(&self.mouseButton);
                try r.read_varint(&self.mode);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.changedSlots = allocator.alloc(@TypeOf(self.changedSlots[0]), length_0);
                for (0..length_0) |i_0| {
                    try r.read_i16(&self.changedSlots[i_0].location);
                    try self.changedSlots[i_0].item.read(r, allocator);
                }
                try self.cursorItem.read(r, allocator);
            }
        };

        pub const packet_teleport_confirm = struct {
            teleportId: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.teleportId);
            }
        };

        pub const packet_enchant_item = struct {
            windowId: i8,
            enchantment: i8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i8(&self.windowId);
                try r.read_i8(&self.enchantment);
            }
        };

        pub const packet_steer_vehicle = struct {
            sideways: f32,
            forward: f32,
            jump: u8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_f32(&self.sideways);
                try r.read_f32(&self.forward);
                try r.read_u8(&self.jump);
            }
        };

        pub const packet_edit_book = struct {
            hand: i32,
            pages: []string,
            title: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.hand);
                var length_0: i32 = undefined;
                try r.read_varint(&length_0);
                self.pages = allocator.alloc(@TypeOf(self.pages[0]), length_0);
                for (0..length_0) |i_0| {
                    try protocol_support.todo(r, &self.pages[i_0]);
                }
                try protocol_support.todo(r, &self.title);
            }
        };

        pub const packet_generate_structure = struct {
            location: position,
            levels: i32,
            keepJigsaws: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.location);
                try r.read_varint(&self.levels);
                try r.read_bool(&self.keepJigsaws);
            }
        };

        pub const packet_block_dig = struct {
            status: i32,
            location: position,
            face: i8,
            sequence: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.status);
                try protocol_support.todo(r, &self.location);
                try r.read_i8(&self.face);
                try r.read_varint(&self.sequence);
            }
        };

        pub const packet_arm_animation = struct {
            hand: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.hand);
            }
        };

        pub const packet_tab_complete = struct {
            transactionId: i32,
            text: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.transactionId);
                try protocol_support.todo(r, &self.text);
            }
        };

        pub const packet_use_item = struct {
            hand: i32,
            sequence: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.hand);
                try r.read_varint(&self.sequence);
            }
        };

        pub const packet_craft_recipe_request = struct {
            windowId: i8,
            recipe: string,
            makeAll: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i8(&self.windowId);
                try protocol_support.todo(r, &self.recipe);
                try r.read_bool(&self.makeAll);
            }
        };

        pub const packet_position_look = struct {
            x: f64,
            y: f64,
            z: f64,
            yaw: f32,
            pitch: f32,
            onGround: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_f64(&self.x);
                try r.read_f64(&self.y);
                try r.read_f64(&self.z);
                try r.read_f32(&self.yaw);
                try r.read_f32(&self.pitch);
                try r.read_bool(&self.onGround);
            }
        };

        pub const packet_abilities = struct {
            flags: i8,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i8(&self.flags);
            }
        };

        pub const packet_query_entity_nbt = struct {
            transactionId: i32,
            entityId: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.transactionId);
                try r.read_varint(&self.entityId);
            }
        };

        pub const packet_steer_boat = struct {
            leftPaddle: bool,
            rightPaddle: bool,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_bool(&self.leftPaddle);
                try r.read_bool(&self.rightPaddle);
            }
        };

        pub const packet_chat_message = struct {
            message: string,
            timestamp: i64,
            salt: i64,
            signature: protocol_support.Todo,
            offset: i32,
            acknowledged: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.message);
                try r.read_i64(&self.timestamp);
                try r.read_i64(&self.salt);
                try protocol_support.todo(r, &self.signature);
                try r.read_varint(&self.offset);
                try protocol_support.todo(r, &self.acknowledged);
            }
        };

        pub const packet_chat_session_update = struct {
            sessionUUID: protocol_support.UUID,
            expireTime: i64,
            publicKey: protocol_support.Todo,
            signature: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_UUID(&self.sessionUUID);
                try r.read_i64(&self.expireTime);
                try protocol_support.todo(r, &self.publicKey);
                try protocol_support.todo(r, &self.signature);
            }
        };

        pub const packet_spectate = struct {
            target: protocol_support.UUID,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_UUID(&self.target);
            }
        };

        pub const packet_pick_item = struct {
            slot: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.slot);
            }
        };

        pub const packet = struct {
            name: protocol_support.Todo,
            params: protocol_support.Todo,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.name);
                try protocol_support.todo(r, &self.params);
            }
        };

        pub const packet_update_jigsaw_block = struct {
            location: position,
            name: string,
            target: string,
            pool: string,
            finalState: string,
            jointType: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.location);
                try protocol_support.todo(r, &self.name);
                try protocol_support.todo(r, &self.target);
                try protocol_support.todo(r, &self.pool);
                try protocol_support.todo(r, &self.finalState);
                try protocol_support.todo(r, &self.jointType);
            }
        };

        pub const packet_held_item_slot = struct {
            slotId: i16,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_i16(&self.slotId);
            }
        };

        pub const packet_message_acknowledgement = struct {
            count: i32,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try r.read_varint(&self.count);
            }
        };

        pub const packet_update_sign = struct {
            location: position,
            isFrontText: bool,
            text1: string,
            text2: string,
            text3: string,
            text4: string,

            pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
                protocol_support.maybe_unused(allocator);
                protocol_support.maybe_unused(r);
                protocol_support.maybe_unused(self);
                try protocol_support.todo(r, &self.location);
                try r.read_bool(&self.isFrontText);
                try protocol_support.todo(r, &self.text1);
                try protocol_support.todo(r, &self.text2);
                try protocol_support.todo(r, &self.text3);
                try protocol_support.todo(r, &self.text4);
            }
        };


    };
};
