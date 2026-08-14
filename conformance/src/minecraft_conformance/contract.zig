pub const protocol_version: u16 = 1;
pub const minecraft_version = "1.21.8";

pub const Capability = packed struct(u8) {
    fixture_restore: bool = false,
    stage_serverbound_packets: bool = false,
    controlled_tick: bool = false,
    capture_clientbound_packets: bool = false,
    stable_connection_identities: bool = false,
    persistent_restart: bool = false,
    _: u2 = 0,
};

pub const TargetKind = enum { vanilla, fabric, paper, lightning_rod, pumpkin };

pub const TargetInfo = struct {
    name: []const u8,
    kind: TargetKind,
    minecraft: []const u8,
    capabilities: Capability,

    pub fn require(self: TargetInfo, required: Capability) !void {
        inline for (.{ "fixture_restore", "stage_serverbound_packets", "controlled_tick", "capture_clientbound_packets", "stable_connection_identities", "persistent_restart" }) |field| {
            if (@field(required, field) and !@field(self.capabilities, field)) return error.MissingCapability;
        }
    }
};

pub const black_box_capabilities = Capability{
    .fixture_restore = true,
    .stage_serverbound_packets = true,
    .controlled_tick = true,
    .capture_clientbound_packets = true,
    .stable_connection_identities = true,
};

pub const persistent_restart_capability = Capability{
    .persistent_restart = true,
};
