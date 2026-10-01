const std = @import("std");

pub const Json = struct {
    builder: *std.Build,
    document: std.json.Value,

    pub fn read(b: *std.Build, source: std.Build.LazyPath) Json {
        const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, source.getPath(b), b.allocator, .unlimited) catch @panic("cannot read JSON");
        return .{
            .builder = b,
            .document = std.json.parseFromSliceLeaky(std.json.Value, b.allocator, bytes, .{}) catch @panic("invalid JSON"),
        };
    }

    pub fn write(self: Json) std.Build.LazyPath {
        const bytes = std.json.Stringify.valueAlloc(self.builder.allocator, self.document, .{}) catch @panic("out of memory");
        return self.builder.addWriteFiles().add("protocol.json", bytes);
    }
};

pub const Codegen = struct {
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    support: *std.Build.Module,
    packets: *std.Build.Step.Compile,
    registries: *std.Build.Step.Compile,

    pub const Configuration = struct {
        tools: *std.Build.Dependency,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        support: *std.Build.Module,
    };

    pub const Schema = struct {
        input: std.Build.LazyPath,
        version: std.Build.LazyPath,
        protocol_number: ?i32 = null,
        output: []const u8,
    };

    pub const Registry = struct {
        data: Data,
        canonical: Data,
        canonical_snapshot: std.Build.LazyPath,
        output: []const u8,
    };

    pub const Data = struct {
        root: std.Build.LazyPath,
        paths: std.json.ObjectMap,

        pub fn init(b: *std.Build, root: std.Build.LazyPath, version: []const u8) Data {
            const filename = root.path(b, "data/dataPaths.json").getPath(b);
            const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, filename, b.allocator, .limited(1024 * 1024)) catch @panic("cannot read Minecraft data paths");
            const document = std.json.parseFromSliceLeaky(std.json.Value, b.allocator, bytes, .{}) catch @panic("invalid Minecraft data paths");
            const paths = document.object.get("pc").?.object.get(version) orelse @panic("missing Minecraft data version");
            return .{ .root = root, .paths = paths.object };
        }

        pub fn path(self: Data, b: *std.Build, filename: []const u8) std.Build.LazyPath {
            const key = std.fs.path.stem(filename);
            const directory = self.paths.get(key) orelse std.debug.panic("missing Minecraft data table: {s}", .{key});
            return self.root.path(b, b.fmt("data/{s}/{s}", .{ directory.string, filename }));
        }
    };

    pub fn init(b: *std.Build, config: Configuration) Codegen {
        return .{
            .builder = b,
            .target = config.target,
            .optimize = config.optimize,
            .support = config.support,
            .packets = config.tools.artifact("protocol-codegen"),
            .registries = config.tools.artifact("registry-codegen"),
        };
    }

    pub fn schema(self: Codegen, options: Schema) *std.Build.Module {
        const b = self.builder;
        const command = b.addRunArtifact(self.packets);
        command.addFileArg(options.input);
        const output = command.addOutputFileArg(options.output);
        command.addFileArg(options.version);
        if (options.protocol_number) |number| command.addArg(b.fmt("{d}", .{number}));
        return b.createModule(.{
            .root_source_file = output,
            .target = self.target,
            .optimize = self.optimize,
            .imports = &.{.{ .name = "protocol_support", .module = self.support }},
        });
    }

    pub fn registry(self: Codegen, options: Registry) *std.Build.Module {
        const b = self.builder;
        const command = b.addRunArtifact(self.registries);
        inline for (.{ "blocks.json", "items.json", "entities.json", "sounds.json", "materials.json", "blockCollisionShapes.json", "enchantments.json", "protocol.json", "biomes.json", "effects.json", "attributes.json" }) |name|
            command.addFileArg(options.data.path(b, name));
        inline for (.{ "blocks.json", "items.json", "entities.json", "sounds.json", "effects.json", "attributes.json" }) |name|
            command.addFileArg(options.canonical.path(b, name));
        command.addFileArg(options.canonical_snapshot);
        return b.createModule(.{
            .root_source_file = command.addOutputFileArg(options.output),
            .target = self.target,
            .optimize = self.optimize,
        });
    }
};
