const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const names = .{ "vanilla", "game_data", "economy" };
    var imports: [names.len]std.Build.Module.Import = undefined;

    inline for (names, 0..) |name, index| {
        const dependency = b.dependency(name, .{ .target = target, .optimize = optimize });
        imports[index] = .{
            .name = name,
            .module = dependency.module(if (std.mem.eql(u8, name, "vanilla")) "lightning_rod_vanilla_1_21_6" else name),
        };
    }

    const module = b.addModule("shop", .{
        .root_source_file = b.path("src/shop.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    const check = b.addLibrary(.{ .name = "shop", .root_module = module });
    b.step("check", "Check the Shop module").dependOn(&check.step);
}
