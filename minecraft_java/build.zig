const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const encoding = b.dependency("encoding", .{ .target = target, .optimize = optimize });
    const sessions = b.dependency("sessions", .{ .target = target, .optimize = optimize });
    const module = b.addModule("minecraft_java", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sessions", .module = sessions.module("sessions") },
            .{ .name = "support", .module = encoding.module("encoding") },
            .{ .name = "deflate", .module = b.dependency("deflate", .{ .target = target, .optimize = optimize }).module("deflate") },
        },
    });
    b.step("check", "Check Java protocol support").dependOn(&b.addLibrary(.{ .name = "minecraft_java", .root_module = module }).step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/compression.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "java", .module = module }, .{ .name = "sessions", .module = sessions.module("sessions") } },
    }) });
    const test_step = b.step("test", "Test packet compression, framing, encryption and RSA");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const rsa_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/rsa.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "java", .module = module }},
    }) });
    const cipher_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/cipher.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "java", .module = module }},
    }) });
    test_step.dependOn(&b.addRunArtifact(cipher_tests).step);
    const test_rsa = b.addRunArtifact(rsa_tests);
    test_rsa.setCwd(b.path("."));
    test_step.dependOn(&test_rsa.step);
    b.step("test-encryption", "Verify RSA key parsing and login decryption").dependOn(&test_rsa.step);
}
