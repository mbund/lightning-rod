const std = @import("std");
const manifest = @import("protocols.zig");

pub const Result = struct {
    nbt: *std.Build.Module,
    support: *std.Build.Module,
    wire: *std.Build.Module,
    registry: *std.Build.Module,
    catalog: *std.Build.Module,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Result {
    const minecraft_data = b.dependency("minecraft_data", .{});
    const protocol_codegen = tool(b, "codegen", "codegen/codegen.zig");
    const registry_codegen = tool(b, "registry_codegen", "codegen/registry_codegen.zig");
    const catalog_codegen = tool(b, "protocol_catalog_codegen", "codegen/protocol_catalog_codegen.zig");
    const nbt = module(b, "nbt", "src/nbt.zig", target, optimize);
    const support = b.addModule("protocol_support", .{
        .root_source_file = b.path("codegen/protocol_support.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nbt", .module = nbt }},
    });
    const registries = addRegistries(b, registry_codegen, minecraft_data, target, optimize);
    const schemas = addSchemas(b, protocol_codegen, minecraft_data, support, target, optimize);
    const catalog = addCatalog(b, catalog_codegen, schemas, registries, target, optimize);
    return .{
        .nbt = nbt,
        .support = support,
        .wire = schemas[manifest.versions[manifest.default].schema],
        .registry = registries[manifest.canonical],
        .catalog = catalog,
    };
}

fn addRegistries(
    b: *std.Build,
    codegen: *std.Build.Step.Compile,
    data: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) [manifest.versions.len]*std.Build.Module {
    var modules: [manifest.versions.len]*std.Build.Module = undefined;
    for (manifest.versions, 0..) |version, index| modules[index] = addRegistry(
        b,
        codegen,
        data,
        target,
        optimize,
        version.minecraft_version,
        manifest.versions[manifest.canonical].minecraft_version,
        index,
    );
    return modules;
}

fn addRegistry(
    b: *std.Build,
    codegen: *std.Build.Step.Compile,
    data: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: []const u8,
    canonical: []const u8,
    index: usize,
) *std.Build.Module {
    const command = b.addRunArtifact(codegen);
    inline for (.{ "blocks.json", "items.json", "entities.json", "sounds.json", "materials.json", "recipes.json", "blockCollisionShapes.json", "enchantments.json", "protocol.json" }) |name|
        command.addFileArg(data.path(b.fmt("data/pc/{s}/{s}", .{ version, name })));
    inline for (.{ "blocks.json", "items.json", "entities.json" }) |name|
        command.addFileArg(data.path(b.fmt("data/pc/{s}/{s}", .{ canonical, name })));
    return generatedModule(b, command, b.fmt("protocol_registry_{}.zig", .{index}), target, optimize);
}

fn addSchemas(
    b: *std.Build,
    codegen: *std.Build.Step.Compile,
    data: *std.Build.Dependency,
    support: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) [manifest.schemas.len]*std.Build.Module {
    var modules: [manifest.schemas.len]*std.Build.Module = undefined;
    for (manifest.schemas, 0..) |schema, index| {
        const command = b.addRunArtifact(codegen);
        command.addFileArg(data.path(b.fmt("data/pc/{s}/protocol.json", .{schema.minecraft_data_version})));
        modules[index] = generatedModule(b, command, b.fmt("protocol_schema_{}.zig", .{index}), target, optimize);
        modules[index].addImport("protocol_support", support);
    }
    return modules;
}

fn addCatalog(
    b: *std.Build,
    codegen: *std.Build.Step.Compile,
    schemas: [manifest.schemas.len]*std.Build.Module,
    registries: [manifest.versions.len]*std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const command = b.addRunArtifact(codegen);
    const source = command.addOutputFileArg("protocol_catalog.zig");
    command.addArg(b.fmt("{}", .{manifest.schemas.len}));
    command.addArg(b.fmt("{}", .{manifest.versions.len}));
    command.addArg(b.fmt("{}", .{manifest.default}));
    command.addArg(b.fmt("{}", .{manifest.canonical}));
    for (manifest.versions) |version| addVersionArguments(b, command, version);
    const result = b.addModule("protocol_catalog", .{
        .root_source_file = source,
        .target = target,
        .optimize = optimize,
    });
    for (schemas, 0..) |schema, index| result.addImport(b.fmt("protocol_schema_{}", .{index}), schema);
    for (registries, 0..) |registry, index| result.addImport(b.fmt("protocol_registry_{}", .{index}), registry);
    return result;
}

fn addVersionArguments(b: *std.Build, command: *std.Build.Step.Run, version: manifest.Version) void {
    command.addArg(version.minecraft_version);
    command.addArg(b.fmt("{}", .{version.protocol_number}));
    command.addArg(b.fmt("{}", .{version.schema}));
    command.addArg(b.fmt("{}", .{version.accepted_names.len}));
    for (version.accepted_names) |name| command.addArg(name);
}

fn tool(b: *std.Build, name: []const u8, path: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
}

fn module(b: *std.Build, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.addModule(name, .{ .root_source_file = b.path(path), .target = target, .optimize = optimize });
}

fn generatedModule(
    b: *std.Build,
    command: *std.Build.Step.Run,
    output: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = command.addOutputFileArg(output),
        .target = target,
        .optimize = optimize,
    });
}
