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
    nbt: *std.Build.Module,
    minimum_minecraft_version: []const u8,
    output_prefix: []const u8,
) Result {
    const selected_versions = manifest.fromMinimumMinecraftVersion(minimum_minecraft_version) orelse
        std.debug.panic("unknown protocol minimum '{s}'", .{minimum_minecraft_version});
    const minimum_release = manifest.releaseIndex(minimum_minecraft_version).?;
    if (manifest.default < minimum_release or manifest.canonical < minimum_release)
        std.debug.panic("protocol minimum '{s}' excludes the canonical protocol", .{minimum_minecraft_version});
    const minecraft_data = b.dependency("minecraft_data", .{});
    const protocol_codegen = tool(b, "codegen", "codegen/codegen.zig");
    const registry_codegen = tool(b, "registry_codegen", "codegen/registry_codegen.zig");
    const catalog_codegen = tool(b, "protocol_catalog_codegen", "codegen/protocol_catalog_codegen.zig");
    const support = b.addModule("protocol_support", .{
        .root_source_file = b.path("codegen/protocol_support.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nbt", .module = nbt }},
    });
    const schema_indices = selectedSchemaIndices(b, selected_versions);
    const registries = addRegistries(
        b,
        registry_codegen,
        minecraft_data,
        target,
        optimize,
        selected_versions,
        manifest.versions[manifest.canonical].minecraft_version,
        output_prefix,
    );
    const schemas = addSchemas(b, protocol_codegen, minecraft_data, support, target, optimize, schema_indices, output_prefix);
    const catalog = addCatalog(
        b,
        catalog_codegen,
        schemas,
        schema_indices,
        registries,
        target,
        optimize,
        selected_versions,
        minimum_release,
        output_prefix,
    );
    return .{
        .nbt = nbt,
        .support = support,
        .wire = schemas[schemaIndex(schema_indices, manifest.versions[manifest.default].schema)],
        .registry = registries[manifest.canonical - minimum_release],
        .catalog = catalog,
    };
}

fn selectedSchemaIndices(b: *std.Build, versions: []const manifest.Version) []const usize {
    const indices = b.allocator.alloc(usize, manifest.schemas.len) catch @panic("out of memory");
    var count: usize = 0;
    for (versions) |version| {
        var present = false;
        for (indices[0..count]) |index| {
            present = present or index == version.schema;
        }
        if (!present) {
            indices[count] = version.schema;
            count += 1;
        }
    }
    return indices[0..count];
}

fn addRegistries(
    b: *std.Build,
    codegen: *std.Build.Step.Compile,
    data: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    versions: []const manifest.Version,
    canonical_version: []const u8,
    output_prefix: []const u8,
) []*std.Build.Module {
    const modules = b.allocator.alloc(*std.Build.Module, versions.len) catch @panic("out of memory");
    for (versions, 0..) |version, index| modules[index] = addRegistry(
        b,
        codegen,
        data,
        target,
        optimize,
        version.minecraft_version,
        canonical_version,
        index,
        output_prefix,
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
    output_prefix: []const u8,
) *std.Build.Module {
    const command = b.addRunArtifact(codegen);
    inline for (.{ "blocks.json", "items.json", "entities.json", "sounds.json", "materials.json", "recipes.json", "blockCollisionShapes.json", "enchantments.json", "protocol.json", "biomes.json" }) |name|
        command.addFileArg(data.path(b.fmt("data/pc/{s}/{s}", .{ version, name })));
    inline for (.{ "blocks.json", "items.json", "entities.json" }) |name|
        command.addFileArg(data.path(b.fmt("data/pc/{s}/{s}", .{ canonical, name })));
    return generatedModule(b, command, b.fmt("{s}_registry_{}.zig", .{ output_prefix, index }), target, optimize);
}

fn addSchemas(
    b: *std.Build,
    codegen: *std.Build.Step.Compile,
    data: *std.Build.Dependency,
    support: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    schema_indices: []const usize,
    output_prefix: []const u8,
) []*std.Build.Module {
    const modules = b.allocator.alloc(*std.Build.Module, schema_indices.len) catch @panic("out of memory");
    for (schema_indices, 0..) |schema_index, index| {
        const schema = manifest.schemas[schema_index];
        const command = b.addRunArtifact(codegen);
        command.addFileArg(data.path(b.fmt("data/pc/{s}/protocol.json", .{schema.minecraft_data_version})));
        modules[index] = generatedModule(b, command, b.fmt("{s}_schema_{}.zig", .{ output_prefix, index }), target, optimize);
        modules[index].addImport("protocol_support", support);
    }
    return modules;
}

fn addCatalog(
    b: *std.Build,
    codegen: *std.Build.Step.Compile,
    schemas: []*std.Build.Module,
    schema_indices: []const usize,
    registries: []*std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    versions: []const manifest.Version,
    minimum_release: usize,
    output_prefix: []const u8,
) *std.Build.Module {
    const command = b.addRunArtifact(codegen);
    const source = command.addOutputFileArg(b.fmt("{s}_catalog.zig", .{output_prefix}));
    command.addArg(b.fmt("{}", .{schemas.len}));
    command.addArg(b.fmt("{}", .{versions.len}));
    command.addArg(b.fmt("{}", .{manifest.default - minimum_release}));
    command.addArg(b.fmt("{}", .{manifest.canonical - minimum_release}));
    command.addArg(b.fmt("{}", .{minimum_release}));
    for (versions) |version| addVersionArguments(b, command, version, schemaIndex(schema_indices, version.schema));
    const result = b.addModule("protocol_catalog", .{
        .root_source_file = source,
        .target = target,
        .optimize = optimize,
    });
    for (schemas, 0..) |schema, index| result.addImport(b.fmt("protocol_schema_{}", .{index}), schema);
    for (registries, 0..) |registry, index| result.addImport(b.fmt("protocol_registry_{}", .{index}), registry);
    return result;
}

fn addVersionArguments(
    b: *std.Build,
    command: *std.Build.Step.Run,
    version: manifest.Version,
    schema: usize,
) void {
    command.addArg(version.minecraft_version);
    command.addArg(b.fmt("{}", .{version.protocol_number}));
    command.addArg(b.fmt("{}", .{schema}));
    command.addArg(b.fmt("{}", .{version.accepted_names.len}));
    for (version.accepted_names) |name| command.addArg(name);
}

fn schemaIndex(indices: []const usize, original: usize) usize {
    for (indices, 0..) |index, selected| if (index == original) return selected;
    unreachable;
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
