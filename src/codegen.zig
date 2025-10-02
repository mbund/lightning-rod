const protocol_support = @import("protocol_support.zig");
const previousMessages = "todo";

const chunkBlockEntity = struct {
    anon: "todo",
    y: i16,
    type: i32,
    nbtData: protocol_support.optionalNbt,
};

const entityMetadataItem = "todo";

const entityMetadata = "todo";

const vec3f = struct {
    x: f32,
    y: f32,
    z: f32,
};

const ItemSoundHolder = "todo";

const packedChunkPos = struct {
    z: i32,
    x: i32,
};

const tags = "todo";

const soundSource = "todo";

const vec4f = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

const particleData = "todo";

const minecraft_simple_recipe_format = struct {
    category: i32,
};

const position = "todo";

const minecraft_smelting_format = struct {
    group: string,
    category: i32,
    ingredient: ingredient,
    result: slot,
    experience: f32,
    cookTime: i32,
};

const chat_session = "todo";

const ingredient = "todo";

const slot = struct {
    present: bool,
    anon: "todo",
};

const string = "todo";

const particle = struct {
    particleId: i32,
    data: "todo",
};

const ByteArray = "todo";

const command_node = struct {
    flags: "todo",
    children: "todo",
    redirectNode: "todo",
    extraNodeData: "todo",
};

const ItemSoundEvent = struct {
    soundName: string,
    fixedRange: "todo",
};

const game_profile = struct {
    name: string,
    properties: "todo",
};

const vec3f64 = struct {
    x: f64,
    y: f64,
    z: f64,
};


