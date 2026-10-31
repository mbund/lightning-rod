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
        },
    });
    const source = b.dependency("libdeflate", .{});
    const library = b.addObject(.{
        .name = "deflate",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/libdeflate.zig"), .target = target, .optimize = optimize }),
    });
    library.root_module.addIncludePath(source.path(""));
    library.root_module.addCSourceFiles(.{
        .root = source.path(""),
        .files = &.{
            "lib/arm/cpu_features.c", "lib/x86/cpu_features.c",
            "lib/deflate_compress.c", "lib/deflate_decompress.c",
            "lib/adler32.c",          "lib/zlib_compress.c",
            "lib/zlib_decompress.c",
        },
        // Zig's Clang rejects upstream AVX-512 VNNI target attributes.
        .flags = &.{ "-std=c99", "-DLIBDEFLATE_STATIC", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI", "-ffreestanding", "-DFREESTANDING" },
    });
    module.addObject(library);
    b.step("check", "Check Java protocol support").dependOn(&b.addLibrary(.{ .name = "minecraft_java", .root_module = module }).step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/compression.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "java", .module = module }, .{ .name = "sessions", .module = sessions.module("sessions") } },
    }) });
    const test_step = b.step("test", "Test packet compression, framing and RSA");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const rsa_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/rsa.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "java", .module = module }},
    }) });
    const test_rsa = b.addRunArtifact(rsa_tests);
    test_rsa.setCwd(b.path("."));
    test_step.dependOn(&test_rsa.step);
    b.step("test-encryption", "Verify RSA key parsing and login decryption").dependOn(&test_rsa.step);
}
