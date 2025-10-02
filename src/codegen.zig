const protocol_support = @import("protocol_support.zig");
pub const previousMessages = protocol_support.Todo;

pub const chunkBlockEntity = struct {
    anon: protocol_support.Todo,
    y: i16,
    type: i32,
    nbtData: protocol_support.optionalNbt,

    fn read(self: *@This(), r: *protocol_support.Reader) !void {
        protocol_support.todo(&self.anon, r);
        r.read_i16(&self.y);
        r.read_varint(&self.type);
        r.read_optionalNbt(&self.nbtData);
    }
};

pub const entityMetadataItem = protocol_support.Todo;

pub const entityMetadata = protocol_support.Todo;

pub const vec3f = struct {
    x: f32,
    y: f32,
    z: f32,

    fn read(self: *@This(), r: *protocol_support.Reader) !void {
        r.read_f32(&self.x);
        r.read_f32(&self.y);
        r.read_f32(&self.z);
    }
};

pub const ItemSoundHolder = protocol_support.Todo;

pub const packedChunkPos = struct {
    z: i32,
    x: i32,

    fn read(self: *@This(), r: *protocol_support.Reader) !void {
        r.read_i32(&self.z);
        r.read_i32(&self.x);
    }
};

pub const tags = protocol_support.Todo;

pub const soundSource = protocol_support.Todo;

pub const vec4f = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    fn read(self: *@This(), r: *protocol_support.Reader) !void {
        r.read_f32(&self.x);
        r.read_f32(&self.y);
        r.read_f32(&self.z);
        r.read_f32(&self.w);
    }
};

pub const particleData = protocol_support.Todo;

pub const minecraft_simple_recipe_format = struct {
    category: i32,

    fn read(self: *@This(), r: *protocol_support.Reader) !void {
        r.read_varint(&self.category);
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

    fn read(self: *@This(), r: *protocol_support.Reader) !void {
        protocol_support.todo(&self.group, r);
        r.read_varint(&self.category);
        protocol_support.todo(&self.ingredient, r);
        slot.read(self.result, r);
        r.read_f32(&self.experience);
        r.read_varint(&self.cookTime);
    }
};

pub const chat_session = protocol_support.Todo;

pub const ingredient = protocol_support.Todo;

pub const slot = struct {
    present: bool,
    anon: protocol_support.Todo,

    fn read(self: *@This(), r: *protocol_support.Reader) !void {
        r.read_bool(&self.present);
        protocol_support.todo(&self.anon, r);
    }
};

pub const string = protocol_support.Todo;

pub const particle = struct {
    particleId: i32,
    data: protocol_support.Todo,

    fn read(self: *@This(), r: *protocol_support.Reader) !void {
        r.read_varint(&self.particleId);
        protocol_support.todo(&self.data, r);
    }
};

pub const ByteArray = protocol_support.Todo;

pub const command_node = struct {
    flags: protocol_support.Todo,
    children: protocol_support.Todo,
    redirectNode: protocol_support.Todo,
    extraNodeData: protocol_support.Todo,

    fn read(self: *@This(), r: *protocol_support.Reader) !void {
        protocol_support.todo(&self.flags, r);
        protocol_support.todo(&self.children, r);
        protocol_support.todo(&self.redirectNode, r);
        protocol_support.todo(&self.extraNodeData, r);
    }
};

pub const ItemSoundEvent = struct {
    soundName: string,
    fixedRange: protocol_support.Todo,

    fn read(self: *@This(), r: *protocol_support.Reader) !void {
        protocol_support.todo(&self.soundName, r);
        protocol_support.todo(&self.fixedRange, r);
    }
};

pub const game_profile = struct {
    name: string,
    properties: protocol_support.Todo,

    fn read(self: *@This(), r: *protocol_support.Reader) !void {
        protocol_support.todo(&self.name, r);
        protocol_support.todo(&self.properties, r);
    }
};

pub const vec3f64 = struct {
    x: f64,
    y: f64,
    z: f64,

    fn read(self: *@This(), r: *protocol_support.Reader) !void {
        r.read_f64(&self.x);
        r.read_f64(&self.y);
        r.read_f64(&self.z);
    }
};


