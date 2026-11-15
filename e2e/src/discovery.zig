//! Finds tests under a directory: each subdirectory with a test.zon next to its build.zig.

const std = @import("std");
const manifest = @import("manifest.zig");

pub const maximum_tests = 256;

pub const Test = struct {
    /// The subdirectory name, relative to the discovery root.
    directory: []const u8,
    manifest: manifest.Manifest,
};

pub fn discover(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, root: []const u8) ![]const Test {
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var tests: std.ArrayList(Test) = .empty;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const path = try std.fs.path.join(arena, &.{ root, entry.name, "test.zon" });
        const test_manifest = manifest.read(io, gpa, arena, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        std.Io.Dir.cwd().access(io, try std.fs.path.join(arena, &.{ root, entry.name, "build.zig" }), .{}) catch return error.TestWithoutBuild;
        if (tests.items.len == maximum_tests) return error.TooManyTests;
        try tests.append(arena, .{ .directory = try arena.dupe(u8, entry.name), .manifest = test_manifest });
    }
    std.mem.sort(Test, tests.items, {}, struct {
        fn less(_: void, a: Test, b: Test) bool {
            return std.mem.lessThan(u8, a.directory, b.directory);
        }
    }.less);
    // Scenario names select a test from anywhere in the suite, so they are unique across tests.
    for (tests.items, 0..) |current, index| {
        for (current.manifest.scenarios) |scenario| {
            for (tests.items[0..index]) |previous| {
                if (previous.manifest.find(scenario.name) != null) {
                    std.log.err("scenario {s} is in both {s} and {s}", .{ scenario.name, previous.directory, current.directory });
                    return error.DuplicateTest;
                }
            }
        }
    }
    return tests.items;
}

/// The test that offers `scenario`.
pub fn find(tests: []const Test, scenario: []const u8) ?Test {
    for (tests) |candidate| if (candidate.manifest.find(scenario) != null) return candidate;
    return null;
}
