const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("deflate", .{ .root_source_file = b.path("src/deflate.zig"), .target = target, .optimize = optimize });
    const source = b.dependency("source", .{});
    const library = b.addObject(.{ .name = "deflate", .root_module = b.createModule(.{ .root_source_file = b.path("src/freestanding.zig"), .target = target, .optimize = optimize }) });
    library.root_module.addIncludePath(source.path(""));
    library.root_module.addCSourceFiles(.{
        .root = source.path(""),
        .files = &.{ "lib/arm/cpu_features.c", "lib/x86/cpu_features.c", "lib/deflate_decompress.c", "lib/adler32.c", "lib/deflate_compress.c", "lib/zlib_compress.c", "lib/zlib_decompress.c" },
        // Zig's Clang rejects upstream AVX-512 VNNI target attributes.
        .flags = &.{ "-std=c99", "-DLIBDEFLATE_STATIC", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI", "-ffreestanding", "-DFREESTANDING" },
    });
    module.addObject(library);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "deflate", .module = module }} }) });
    b.step("test", "Verify bounded compression and reusable DEFLATE fragments").dependOn(&b.addRunArtifact(tests).step);
}
