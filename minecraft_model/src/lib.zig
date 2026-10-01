const chunks = @import("chunks");

pub const Position = struct {
    x: f64,
    y: f64,
    z: f64,
};

pub const BlockPosition = struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const DigAction = enum(i32) { start, cancel, finish, drop_stack, drop_item, release_use, swap_hands };

pub const Dig = struct {
    action: DigAction,
    position: BlockPosition,
    face: i8,
    sequence: i32,
};

pub const Place = struct {
    hand: i32,
    position: BlockPosition,
    face: i32,
    cursor: [3]f32,
    inside: bool,
    border: bool,
    sequence: i32,
};

pub const Rotation = struct {
    yaw: f32,
    pitch: f32,
};

pub const GameMode = enum(i8) { survival, creative, adventure, spectator };

pub const Movement = struct {
    position: ?Position = null,
    rotation: ?Rotation = null,
    on_ground: bool,
    horizontal_collision: bool,
};

pub const EntityFlags = packed struct(u8) {
    burning: bool = false,
    sneaking: bool = false,
    unused: bool = false,
    sprinting: bool = false,
    swimming: bool = false,
    invisible: bool = false,
    glowing: bool = false,
    gliding: bool = false,
};

pub const Action = enum(i32) {
    leave_bed,
    start_sprinting,
    stop_sprinting,
    start_horse_jump,
    stop_horse_jump,
    open_vehicle_inventory,
    start_gliding,
};

pub const InventoryClick = struct {
    window_id: i32,
    state_id: i32,
    slot: i16,
    button: i8,
    mode: i32,
};

pub const Login = struct {
    entity_id: i32,
    world_names: []const []const u8,
    dimension_type: []const u8,
    world_name: []const u8,
    max_players: i32,
    view_distance: i32,
    simulation_distance: i32,
    hashed_seed: i64,
    gamemode: i8,
    sea_level: i32,
};

pub const Chunk = struct {
    x: i32,
    z: i32,
    sections: []const chunks.Lease,
    biome: i32,
    minimum_section: i32,
    skylight: bool,
};
