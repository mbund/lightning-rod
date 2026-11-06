pub const wire = @import("wire");
pub const catalog = @import("catalog");
pub const registry = @import("registry");
pub const support = @import("support");
pub const nbt = @import("nbt");
const java = @import("minecraft_java");
const std = @import("std");
const sessions = @import("sessions");

pub const Handshake = java.Handshake;
pub const implementations = catalog.entries;
comptime {
    for (implementations) |Version|
        if (Version.Bootstrap != implementations[0].Bootstrap)
            @compileError("The standard protocol aggregate requires a shared bootstrap. Compose a custom Sessions endpoint for distinct handshakes.");
}
pub const Default: type = java.RegistryCatalog(implementations);
pub const Endpoint: type = sessions.Endpoint(implementations, implementations[0].Bootstrap, Default);
pub const Input = sessions.Inputs(implementations);

pub fn version(comptime release: []const u8) type {
    for (implementations) |Implementation| {
        for (Implementation.releases) |name| {
            if (std.mem.eql(u8, name, release)) return Implementation;
        }
    }
    @compileError("Minecraft release is not selected in the protocol build: " ++ release);
}

test "renamed chains preserve block states and item IDs across protocols" {
    const canonical_name = if (registry.itemId("minecraft:chain") != null) "minecraft:chain" else "minecraft:iron_chain";
    const item = registry.itemId(canonical_name).?;
    inline for (implementations) |Version| {
        const target = Version.Registry;
        const wire_name = if (target.itemId("minecraft:chain") != null) "minecraft:chain" else "minecraft:iron_chain";
        const mapped_item = target.canonical_item_to_wire[@intCast(item)];
        try std.testing.expectEqual(target.itemId(wire_name).?, mapped_item);
        try std.testing.expectEqual(item, target.wire_item_to_canonical[@intCast(mapped_item)]);
        for ([_][]const u8{ "x", "y", "z" }) |axis| for ([_][]const u8{ "true", "false" }) |waterlogged| {
            var canonical_buffer: [128]u8 = undefined;
            var wire_buffer: [128]u8 = undefined;
            const canonical = try std.fmt.bufPrint(&canonical_buffer, "{s}[axis={s},waterlogged={s}]", .{ canonical_name, axis, waterlogged });
            const wire_state = try std.fmt.bufPrint(&wire_buffer, "{s}[axis={s},waterlogged={s}]", .{ wire_name, axis, waterlogged });
            const from = registry.blockStateId(canonical).?;
            const to = target.blockStateId(wire_state).?;
            try std.testing.expectEqual(to, target.canonical_block_state_to_wire[@intCast(from)]);
            try std.testing.expectEqual(@as(i32, target.block_state_to_block[@intCast(to)]), target.canonical_block_to_wire[registry.block_state_to_block[@intCast(from)]]);
        };
    }
}
