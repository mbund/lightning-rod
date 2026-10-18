const std = @import("std");
const registry = @import("registry");
const canonical_version = @import("canonical_version").value;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(canonical_version);
    // Length framing preserves registry boundaries and the position of every numeric ID.
    inline for (.{ "block_state_names", "item_names", "entity_names", "data_component_names", "biome_names", "enchantment_names" }) |field| {
        const names = @field(registry, field);
        var count: [8]u8 = undefined;
        std.mem.writeInt(u64, &count, names.len, .little);
        hash.update(&count);
        for (names) |name| {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, name.len, .little);
            hash.update(&length);
            hash.update(name);
        }
    }
    var identity: [32]u8 = undefined;
    hash.final(&identity);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = &identity });
}
