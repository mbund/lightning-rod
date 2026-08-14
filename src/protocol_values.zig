pub const SpawnEntity = struct {
    entity_id: i32,
    uuid: u128,
    entity_type: i32,
    x: f64,
    y: f64,
    z: f64,
    pitch: i8,
    yaw: i8,
    head_yaw: i8,
    data: i32,
    velocity_x: i16,
    velocity_y: i16,
    velocity_z: i16,
};

pub const PlayerPosition = struct {
    teleport_id: i32,
    x: f64,
    y: f64,
    z: f64,
    velocity_x: f64,
    velocity_y: f64,
    velocity_z: f64,
    yaw: f32,
    pitch: f32,
};

pub const PlayerInfo = struct {
    uuid: u128,
    name: []const u8,
    gamemode: i32,
};

pub const PlayLogin = struct {
    entity_id: i32,
    world_names: []const []const u8,
    dimension_type: i32,
    world_name: []const u8,
    max_players: i32,
    view_distance: i32,
    simulation_distance: i32,
    hashed_seed: i64,
    gamemode: i8,
    sea_level: i32,
};

pub const Respawn = struct {
    dimension_type: i32,
    world_name: []const u8,
    hashed_seed: i64,
    gamemode: i8,
    sea_level: i32,
};

pub const StatusCommand = union(enum) { request, ping: i64 };

pub const LoginCommand = union(enum) {
    start: struct { username: []const u8, uuid: u128 },
    encryption_response: struct { shared_secret: []const u8, verify_token: []const u8 },
    acknowledged,
};

pub const ConfigurationCommand = enum { ignore, finish, select_known_packs };

pub const Sound = enum(u8) {
    cow_ambient,
    cow_death,
    cow_hurt,
    cow_milk,
    cow_step,
};
