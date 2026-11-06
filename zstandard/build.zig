const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zstandard", .{ .root_source_file = b.path("src/zstandard.zig"), .target = target, .optimize = optimize });
    const source = b.dependency("source", .{});
    const object = b.addObject(.{ .name = "zstandard", .root_module = b.createModule(.{ .target = target, .optimize = optimize }) });
    object.root_module.addSystemIncludePath(std.Build.LazyPath.zig_lib.path(b, b.fmt("libc/include/{s}-linux-musl", .{@tagName(target.result.cpu.arch)})));
    object.root_module.addSystemIncludePath(std.Build.LazyPath.zig_lib.path(b, "libc/include/generic-musl"));
    object.root_module.addCSourceFiles(.{
        .root = source.path("lib"),
        .files = &.{
            "common/debug.c",                      "common/entropy_common.c",     "common/error_private.c",            "common/fse_decompress.c",  "common/xxhash.c",                   "common/zstd_common.c",
            "compress/fse_compress.c",             "compress/hist.c",             "compress/huf_compress.c",           "compress/zstd_compress.c", "compress/zstd_compress_literals.c", "compress/zstd_compress_sequences.c",
            "compress/zstd_compress_superblock.c", "compress/zstd_double_fast.c", "compress/zstd_fast.c",              "compress/zstd_lazy.c",     "compress/zstd_ldm.c",               "compress/zstd_opt.c",
            "compress/zstd_preSplit.c",            "decompress/huf_decompress.c", "decompress/huf_decompress_amd64.S", "decompress/zstd_ddict.c",  "decompress/zstd_decompress.c",      "decompress/zstd_decompress_block.c",
        },
        .flags = &.{ "-std=c99", "-ffreestanding", "-fbuiltin", "-DZSTD_LEGACY_SUPPORT=0", "-DZSTD_DEPS_MALLOC", "-DZSTD_malloc(s)=((void)(s),(void*)0)", "-DZSTD_calloc(n,s)=((void)(n),(void)(s),(void*)0)", "-DZSTD_free(p)=((void)(p))", "-DXXH_NO_STDLIB" },
    });
    module.addObject(object);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zstandard", .module = module }},
    }) });
    b.step("test", "Verify bounded freestanding compression and frame validation").dependOn(&b.addRunArtifact(tests).step);
}
