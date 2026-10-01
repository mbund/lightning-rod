const std = @import("std");
const codegen = @import("protocol_codegen");
const game_data = @import("game_data");
const version = @import("src/version.zig");

pub fn build(b: *std.Build) void {
    const data = codegen.Codegen.Data.init(b, b.dependency(version.data_package, .{}).path(""), version.schema_version);
    var schema = codegen.Json.read(b, data.path(b, "protocol.json"));

    // Prismarine omits the partial matcher's NBT payload and type discriminator.
    const types = &schema.document.object.getPtr("types").?.object;
    const matcher = types.get("DataComponentMatchers").?.array.items[1].array.items[1].object.get("type").?.array.items[1].object.getPtr("type").?;
    std.debug.assert(std.mem.eql(u8, matcher.string, "varint"));
    const definition =
        \\["container", [{"name":"registered","type":"bool"}, {"name":"type","type":"varint"}, {"name":"data","type":"anonymousNbt"}]]
    ;
    const node = std.json.parseFromSliceLeaky(std.json.Value, b.allocator, definition, .{}) catch @panic("invalid matcher schema");
    types.put(b.allocator, "PartialComponentMatcher", node) catch @panic("out of memory");
    matcher.* = .{ .string = "PartialComponentMatcher" };
    _ = (codegen.JavaVersion{
        .minecraft_version = version.minecraft_name,
        .schema_version = version.schema_version,
        .canonical_version = game_data.minecraft_version,
        .data_dependency = version.data_package,
        .schema_input = schema.write(),
    }).add(b);
}
