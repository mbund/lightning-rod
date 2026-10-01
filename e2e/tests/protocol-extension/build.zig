const std = @import("std");
const protocol_codegen = @import("protocol_codegen");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const game_data = b.dependency("game_data", .{ .target = target, .optimize = optimize });
    const data = protocol_codegen.Codegen.Data.init(b, b.dependency("minecraft_data", .{}).path(""), "1.21.8");
    const canonical_data = protocol_codegen.Codegen.Data.init(b, b.dependency("minecraft_data", .{}).path(""), "1.21.9");
    const generator = protocol_codegen.Codegen.init(b, .{
        .tools = b.dependency("protocol_codegen", .{}),
        .target = target,
        .optimize = optimize,
        .support = b.dependency("encoding", .{ .target = target, .optimize = optimize }).module("encoding"),
    });
    const snapshot = b.dependency("registry_snapshotter", .{ .@"minecraft-version" = "1.21.9" }).namedLazyPath("snapshot");
    var canonical_schema = protocol_codegen.Json.read(b, canonical_data.path(b, "protocol.json"));
    var wire_schema = protocol_codegen.Json.read(b, data.path(b, "protocol.json"));
    for ([_]*protocol_codegen.Json{ &canonical_schema, &wire_schema }) |schema| {
        // Prismarine omits the partial matcher's NBT payload.
        const types = &schema.document.object.getPtr("types").?.object;
        const matcher = types.get("DataComponentMatchers").?.array.items[1].array.items[1].object.get("type").?.array.items[1].object.getPtr("type").?;
        std.debug.assert(std.mem.eql(u8, matcher.string, "varint"));
        const definition =
            \\["container", [{"name":"type","type":"varint"}, {"name":"data","type":"anonymousNbt"}]]
        ;
        const node = std.json.parseFromSliceLeaky(std.json.Value, b.allocator, definition, .{}) catch @panic("invalid matcher schema");
        types.put(b.allocator, "PartialComponentMatcher", node) catch @panic("out of memory");
        matcher.* = .{ .string = "PartialComponentMatcher" };
    }
    const canonical = b.createModule(.{
        .root_source_file = b.path("canonical.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "base_data", .module = game_data.module("game_data") },
            .{ .name = "schema", .module = generator.schema(.{ .input = canonical_schema.write(), .version = canonical_data.path(b, "version.json"), .output = "canonical_schema.zig" }) },
            .{ .name = "registry", .module = generator.registry(.{ .data = canonical_data, .canonical = canonical_data, .canonical_snapshot = snapshot, .output = "canonical_registry.zig" }) },
        },
    });
    canonical.addAnonymousImport("registry_snapshot", .{ .root_source_file = snapshot });
    b.dependency("vanilla", .{ .target = target, .optimize = optimize }).module("lightning_rod_vanilla_1_21_6").addImport("game_data", canonical);
    const names = .{ "lightning_rod", "profiles", "reload_execve", "network_stdio", "vanilla", "sessions", "minecraft_packets", "minecraft_java", "storage_local", "game_data", "reload" };
    var imports: [names.len + 3]std.Build.Module.Import = undefined;
    inline for (names, 0..) |name, index| {
        const package = b.dependency(name, .{ .target = target, .optimize = optimize });
        imports[index] = .{ .name = name, .module = if (std.mem.eql(u8, name, "game_data")) canonical else package.module(if (std.mem.eql(u8, name, "vanilla")) "lightning_rod_vanilla_1_21_6" else name) };
    }
    imports[names.len] = .{ .name = "wire", .module = generator.schema(.{
        .input = wire_schema.write(),
        .version = data.path(b, "version.json"),
        .output = "downstream_wire.zig",
    }) };
    imports[names.len + 1] = .{ .name = "registry", .module = generator.registry(.{
        .data = data,
        .canonical = canonical_data,
        .canonical_snapshot = snapshot,
        .output = "downstream_registry.zig",
    }) };
    const protocols = b.createModule(.{
        .root_source_file = b.path("protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports[0 .. names.len + 2],
    });
    protocols.addAnonymousImport("wire_snapshot", .{ .root_source_file = game_data.namedLazyPath("snapshot") });
    imports[names.len + 2] = .{ .name = "protocols", .module = protocols };
    b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols);
    b.dependency("vanilla", .{ .target = target, .optimize = optimize }).module("lightning_rod_vanilla_1_21_6").addImport("protocols", protocols);
    b.installArtifact(b.addExecutable(.{
        .name = "lightning_rod",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    }));
}
