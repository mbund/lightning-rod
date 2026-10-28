const std = @import("std");
const protocol_codegen = @import("protocol_codegen");
const registry_snapshotter = @import("registry_snapshotter");

pub const minecraft_version = std.mem.trim(u8, @embedFile("baseline"), " \t\r\n");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const support = b.dependency("encoding", .{ .target = target, .optimize = optimize }).module("encoding");
    const snapshotter = b.dependency("registry_snapshotter", .{ .@"minecraft-version" = minecraft_version });
    const snapshot = snapshotter.namedLazyPath("snapshot");
    b.addNamedLazyPath("snapshot", snapshot);
    const data = protocol_codegen.Codegen.Data.find(b, b.dependency("minecraft_data", .{}).path(""), minecraft_version) orelse
        protocol_codegen.Codegen.Data.find(b, b.dependency("minecraft_data_current", .{}).path(""), minecraft_version) orelse
        std.debug.panic("missing gameplay baseline data: {s}", .{minecraft_version});
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
    const current = std.mem.eql(u8, registry_snapshotter.apiForVersion(snapshotter.builder, minecraft_version), "current");
    const definition = if (current)
        \\["container", [{"name":"registered","type":"bool"}, {"name":"type","type":"varint"}, {"name":"data","type":"anonymousNbt"}]]
    else
        \\["container", [{"name":"type","type":"varint"}, {"name":"data","type":"anonymousNbt"}]]
    ;
    const node = std.json.parseFromSliceLeaky(std.json.Value, b.allocator, definition, .{}) catch @panic("invalid matcher schema");
    types.put(b.allocator, "PartialComponentMatcher", node) catch @panic("out of memory");
    matcher.* = .{ .string = "PartialComponentMatcher" };
    if (current) {
        // Current holders omit the older outer hasHolder branch.
        const components = &types.get("SlotComponent").?.array.items[1].array.items[1].object.get("type").?.array.items[1].object.getPtr("fields").?.object;
        for ([_][]const u8{ "instrument", "jukebox_playable", "provides_trim_material" }) |name| {
            const component = components.getPtr(name).?;
            const fields = component.array.items[1].array.items;
            std.debug.assert(std.mem.eql(u8, fields[0].object.get("name").?.string, "hasHolder"));
            component.* = fields[1].object.get("type").?.array.items[1].object.get("fields").?.object.get("true").?;
        }
    }
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
    const version = b.addOptions();
    version.addOption([]const u8, "value", minecraft_version);
    module.addOptions("canonical_version", version);
    module.addAnonymousImport("canonical_identity", .{ .root_source_file = identity(b, registry, minecraft_version) });
    module.addAnonymousImport("registry_snapshot", .{ .root_source_file = snapshot });
    b.step("check", "Check the generated gameplay data module").dependOn(&b.addLibrary(.{
        .name = "game_data",
        .root_module = module,
    }).step);
}

pub fn identity(b: *std.Build, registry: *std.Build.Module, version_name: []const u8) std.Build.LazyPath {
    const version = b.addOptions();
    version.addOption([]const u8, "value", version_name);
    const executable = b.addExecutable(.{
        .name = "registry-identity",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/identity.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "registry", .module = b.createModule(.{ .root_source_file = registry.root_source_file }) }},
        }),
    });
    executable.root_module.addOptions("canonical_version", version);
    return b.addRunArtifact(executable).addOutputFileArg("identity.bin");
}
