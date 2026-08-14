const inputs = @import("world/inputs.zig");
const player_store = @import("world/players.zig");
const geometry = @import("world/geometry.zig");
const protocol_values = @import("protocol_values.zig");
pub const PlayerMoved = struct { slot: u16, previous: inputs.PreviousMovement };
pub const ArmSwing = struct { slot: u16, hand: i32 };
pub const BlockBreakAnimation = struct {
    world: @import("world/identity.zig").Handle,
    slot: u16,
    pos: geometry.BlockPos,
    stage: i8,
};
pub const AcknowledgeDig = struct { slot: u16, sequence: i32 };
pub const BlockChanged = struct {
    world: @import("world/identity.zig").Handle,
    pos: geometry.BlockPos,
    block_state: i32,
};
pub const BlockCorrection = struct { slot: u16, pos: geometry.BlockPos };
pub const HotbarChanged = struct { slot: u16, hotbar_slot: u4 };
pub const GamemodeChanged = struct { slot: u16, value: player_store.GameMode };
pub const ItemCollected = struct { item_entity_id: i32, collector_entity_id: i32, count: u8 };
pub const InventorySlotChanged = struct { slot: u16, inventory_slot: i32 };
pub const PlayerScreenSlotChanged = struct { slot: u16, screen_slot: i16 };
pub const ContainerClosed = struct { slot: u16, window_id: i32 };
pub const ContainerProperty = struct { id: i16, value: i16 };
pub const ContainerOpened = struct {
    slot: u16,
    title: []const u8,
    properties: []const ContainerProperty = &.{},
};

pub const ChestViewersChanged = struct {
    world: @import("world/identity.zig").Handle,
    position: geometry.BlockPos,
    viewers: u8,
};
pub const LivingDestroyed = struct { index: u16, entity_id: i32 };
pub const LivingDamaged = struct { index: u16, attacker_slot: u16 };
pub const LivingFell = struct { index: u16 };
pub const LivingVelocityChanged = struct { index: u16, x: f64, y: f64, z: f64 };
pub const LivingDied = struct { index: u16, attacker_slot: u16 };
pub const LivingEquipmentChanged = struct { index: u16, equipment_slot: u8 };
pub const LivingStatus = struct { index: u16, status: i8 };
pub const LivingSound = struct {
    index: u16,
    sound: protocol_values.Sound,
    volume: f32,
    pitch: f32,
    seed: i64,
};
pub const PlayerDamageSource = union(enum) {
    mob: i32,
    player: u16,
};
pub const PlayerDamaged = struct {
    slot: u16,
    source: PlayerDamageSource,
    knockback: ?geometry.Vec3 = null,
    fatal: bool,
};
pub const PlayerFell = struct {
    slot: u16,
    fatal: bool,
};
