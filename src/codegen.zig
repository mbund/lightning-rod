const std = @import("std");
const protocol_support = @import("protocol_support.zig");

pub const previousMessages = []struct {
    id: i32,
    signature: protocol_support.Todo,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
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
        try r.read_i32(&self.z);
        try r.read_i32(&self.x);
    }
};

pub const tags = []struct {
    tagName: string,
    entries: []i32,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        try protocol_support.todo(r, &self.tagName);
        var length_i: i32 = undefined;
        try r.read_varint(&length_i);
        self.entries = allocator.alloc(@TypeOf(self.entries[0]), length_i);
        for (0..length_i) |i| {
            try r.read_varint(&self.entries[i]);
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
        try protocol_support.todo(r, &self.group);
        try r.read_varint(&self.category);
        var length_i: i32 = undefined;
        try r.read_varint(&length_i);
        self.ingredient = allocator.alloc(@TypeOf(self.ingredient[0]), length_i);
        for (0..length_i) |i| {
            try self.ingredient[i].read(r, allocator);
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
        try protocol_support.todo(r, &self.flags);
        var length_i: i32 = undefined;
        try r.read_varint(&length_i);
        self.children = allocator.alloc(@TypeOf(self.children[0]), length_i);
        for (0..length_i) |i| {
            try r.read_varint(&self.children[i]);
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
            try protocol_support.todo(r, &self.name);
            try protocol_support.todo(r, &self.value);
            try protocol_support.todo(r, &self.signature);
        }
    },

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        try protocol_support.todo(r, &self.name);
        var length_i: i32 = undefined;
        try r.read_varint(&length_i);
        self.properties = allocator.alloc(@TypeOf(self.properties[0]), length_i);
        for (0..length_i) |i| {
            try protocol_support.todo(r, &self.properties[i].name);
            try protocol_support.todo(r, &self.properties[i].value);
            try protocol_support.todo(r, &self.properties[i].signature);
        }
    }
};

pub const vec3f64 = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {
        protocol_support.maybe_unused(allocator);
        try r.read_f64(&self.x);
        try r.read_f64(&self.y);
        try r.read_f64(&self.z);
    }
};


