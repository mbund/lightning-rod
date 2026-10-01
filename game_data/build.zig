const std = @import("std");
const protocol_codegen = @import("protocol_codegen");

pub const minecraft_version = "1.21.8";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const support = b.dependency("encoding", .{ .target = target, .optimize = optimize }).module("encoding");
    const snapshot = b.dependency("registry_snapshotter", .{ .@"minecraft-version" = minecraft_version }).namedLazyPath("snapshot");
    b.addNamedLazyPath("snapshot", snapshot);
    const data = protocol_codegen.Codegen.Data.init(b, b.dependency("minecraft_data", .{}).path(""), minecraft_version);
    b.addNamedLazyPath("data", data.root);
    const generator = protocol_codegen.Codegen.init(b, .{
        .tools = b.dependency("protocol_codegen", .{}),
        .target = target,
        .optimize = optimize,
        .support = support,
    });
    var document = protocol_codegen.Json.read(b, data.path(b, "protocol.json"));
    // Prismarine omits the partial matcher's NBT payload.
    const types = &document.document.object.getPtr("types").?.object;
    const matcher = types.get("DataComponentMatchers").?.array.items[1].array.items[1].object.get("type").?.array.items[1].object.getPtr("type").?;
    std.debug.assert(std.mem.eql(u8, matcher.string, "varint"));
    const definition =
        \\["container", [{"name":"type","type":"varint"}, {"name":"data","type":"anonymousNbt"}]]
    ;
    const node = std.json.parseFromSliceLeaky(std.json.Value, b.allocator, definition, .{}) catch @panic("invalid matcher schema");
    types.put(b.allocator, "PartialComponentMatcher", node) catch @panic("out of memory");
    matcher.* = .{ .string = "PartialComponentMatcher" };
    const schema = generator.schema(.{ .input = document.write(), .version = data.path(b, "version.json"), .output = "item_schema.zig" });
    const registry = generator.registry(.{ .data = data, .canonical = data, .canonical_snapshot = snapshot, .output = "registry.zig" });
    b.modules.put(b.allocator, "schema", schema) catch @panic("out of memory");
    b.modules.put(b.allocator, "registry", registry) catch @panic("out of memory");
    const module = b.addModule("game_data", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "schema", .module = schema },
            .{ .name = "registry", .module = registry },
            .{ .name = "support", .module = support },
        },
    });
    module.addAnonymousImport("registry_snapshot", .{ .root_source_file = snapshot });
    b.step("check", "Check the generated gameplay data module").dependOn(&b.addLibrary(.{
        .name = "game_data",
        .root_module = module,
    }).step);
}
