const std = @import("std");
const Codegen = @import("codegen.zig").Codegen;

pub const JavaVersion = struct {
    minecraft_version: []const u8,
    schema_version: []const u8,
    canonical_version: []const u8,
    data_dependency: []const u8 = "minecraft_data",
    schema_input: ?std.Build.LazyPath = null,

    pub fn add(self: JavaVersion, b: *std.Build) *std.Build.Module {
        const target = b.standardTargetOptions(.{});
        const optimize = b.standardOptimizeOption(.{});
        const data = b.dependency(self.data_dependency, .{});
        const gameplay = b.dependency("game_data", .{ .target = target, .optimize = optimize });
        const java = b.dependency("minecraft_java", .{ .target = target, .optimize = optimize });
        const support = b.dependency("encoding", .{ .target = target, .optimize = optimize }).module("encoding");
        const generator = Codegen.init(b, .{
            .tools = b.dependency("protocol_codegen", .{}),
            .target = target,
            .optimize = optimize,
            .support = support,
        });
        const schema_data = Codegen.Data.init(b, data.path(""), self.schema_version);
        const registry_data = Codegen.Data.init(b, data.path(""), self.minecraft_version);
        const canonical = Codegen.Data.init(b, gameplay.namedLazyPath("data"), self.canonical_version);
        const snapshot = b.dependency("registry_snapshotter", .{ .@"minecraft-version" = self.minecraft_version }).namedLazyPath("snapshot");
        const schema = if (self.schema_input == null and std.mem.eql(u8, self.minecraft_version, self.canonical_version))
            gameplay.module("schema")
        else
            generator.schema(.{ .input = self.schema_input orelse schema_data.path(b, "protocol.json"), .version = registry_data.path(b, "version.json"), .output = "schema.zig" });
        const registry = if (std.mem.eql(u8, self.minecraft_version, self.canonical_version))
            gameplay.module("registry")
        else
            generator.registry(.{
                .data = registry_data,
                .canonical = canonical,
                .canonical_snapshot = gameplay.namedLazyPath("snapshot"),
                .output = "registry.zig",
            });
        const module = b.addModule("protocol", .{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minecraft_java", .module = java.module("minecraft_java") },
                .{ .name = "wire", .module = schema },
                .{ .name = "registry", .module = registry },
            },
        });
        b.modules.put(b.allocator, "wire", schema) catch @panic("out of memory");
        module.addAnonymousImport("registry_snapshot", .{ .root_source_file = snapshot });
        const host_support = b.dependency("encoding", .{ .target = b.graph.host, .optimize = .debug }).module("encoding");
        const host_sessions = java.builder.dependency("sessions", .{ .target = b.graph.host, .optimize = .debug }).module("sessions");
        const host_wire = b.createModule(.{
            .root_source_file = schema.root_source_file,
            .target = b.graph.host,
            .optimize = .debug,
            .imports = &.{.{ .name = "protocol_support", .module = host_support }},
        });
        const prepare = b.addExecutable(.{
            .name = "prepare-registries",
            .root_module = b.createModule(.{
                .root_source_file = java.path("src/prepare_registries.zig"),
                .target = b.graph.host,
                .optimize = .debug,
                .imports = &.{
                    .{ .name = "wire", .module = host_wire },
                    .{ .name = "support", .module = host_support },
                    .{ .name = "sessions", .module = host_sessions },
                },
            }),
        });
        const command = b.addRunArtifact(prepare);
        command.addFileArg(snapshot);
        command.addArg(self.minecraft_version);
        const prepared = b.createModule(.{
            .root_source_file = command.addOutputFileArg("registry_packets.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "minecraft_java", .module = java.module("minecraft_java") }},
        });
        prepared.addAnonymousImport("registry_packet_bytes", .{ .root_source_file = command.addOutputFileArg("registry_packets.bin") });
        module.addImport("registry_packets", prepared);
        b.getInstallStep().dependOn(&b.addLibrary(.{ .name = "protocol", .root_module = module }).step);
        return module;
    }
};
