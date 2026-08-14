const identity = @import("identity.zig");

pub const SpawnLight = union(enum) {
    constant: u8,
    uniform: Range,

    pub const Range = struct {
        minimum: u8,
        maximum: u8,
    };
};

pub const MonsterSettings = struct {
    piglin_safe: bool,
    has_raids: bool,
    spawn_light: SpawnLight,
    spawn_block_light_limit: u8,
};

pub const Definition = struct {
    id: []const u8,
    known_pack: bool = false,
    fixed_time: ?i64,
    has_skylight: bool,
    has_ceiling: bool,
    ultrawarm: bool,
    natural: bool,
    coordinate_scale: f64,
    bed_works: bool,
    respawn_anchor_works: bool,
    min_y: i32,
    height: i32,
    logical_height: i32,
    infiniburn: []const u8,
    effects: []const u8,
    ambient_light: f32,
    cloud_height: ?i32,
    monsters: MonsterSettings,
};

pub const Service = struct {
    definitions: []const Definition,

    pub fn definition(self: Service, id: identity.DimensionId) ?*const Definition {
        if (id.index >= self.definitions.len) return null;
        return &self.definitions[id.index];
    }

    pub fn protocolIndex(self: Service, id: identity.DimensionId) ?i32 {
        if (id.index >= self.definitions.len) return null;
        return @intCast(id.index);
    }
};
