const std = @import("std");

const Archive = struct { path: []const u8, hash: ?[]const u8 = null };
const Packager = struct {
    init: std.process.Init,
    allocator: std.mem.Allocator,
    root: []const u8,
    packages: std.StringHashMap(Archive),
    next: usize = 0,

    fn run(self: *Packager, argv: []const []const u8, directory: ?[]const u8) ![]const u8 {
        const result = try std.process.run(self.allocator, self.init.io, .{ .argv = argv, .cwd = if (directory) |path| .{ .path = path } else .inherit, .environ_map = self.init.environ_map, .stdout_limit = .limited(16 * 1024 * 1024), .stderr_limit = .limited(16 * 1024 * 1024) });
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
            return error.PackageCommandFailed;
        }
        return result.stdout;
    }

    fn archive(self: *Packager, path: []const u8) anyerror!Archive {
        const source = try std.Io.Dir.cwd().realPathFileAlloc(self.init.io, path, self.allocator);
        if (self.packages.get(source)) |existing| return if (existing.hash != null) existing else error.DependencyCycle;
        const id = self.next;
        self.next += 1;
        const destination = try std.fmt.allocPrint(self.allocator, "{s}/package-{d}.tar.gz", .{ self.root, id });
        try self.packages.put(source, .{ .path = destination });
        const manifest_path = try std.fs.path.join(self.allocator, &.{ source, "build.zig.zon" });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.init.io, manifest_path, self.allocator, .limited(1024 * 1024));
        const sentinel = try self.allocator.dupeZ(u8, bytes);
        var tokenizer = std.zig.Tokenizer.init(sentinel);
        var tokens: std.ArrayList(std.zig.Token) = .empty;
        while (true) {
            const token = tokenizer.next();
            try tokens.append(self.allocator, token);
            if (token.tag == .eof) break;
            if (token.tag == .invalid) return error.InvalidManifest;
        }
        var manifest: std.Io.Writer.Allocating = .init(self.allocator);
        var copied: usize = 0;
        var included: std.ArrayList([]const u8) = .empty;
        var at: usize = 0;
        while (at + 3 < tokens.items.len) : (at += 1) {
            const items = tokens.items;
            if (items[at].tag != .period or items[at + 1].tag != .identifier or items[at + 2].tag != .equal) continue;
            const name = bytes[items[at + 1].loc.start..items[at + 1].loc.end];
            if (std.mem.eql(u8, name, "path")) {
                const value = items[at + 3];
                if (value.tag != .string_literal) return error.UnsupportedDependencyPath;
                const relative = try std.zig.string_literal.parseAlloc(self.allocator, bytes[value.loc.start..value.loc.end]);
                const dependency = try self.archive(try std.fs.path.resolve(self.allocator, &.{ source, relative }));
                try manifest.writer.writeAll(bytes[copied..items[at].loc.start]);
                try manifest.writer.print(".url = \"file://{s}\", .hash = \"{s}\"", .{ dependency.path, dependency.hash.? });
                copied = value.loc.end;
                at += 3;
            } else if (std.mem.eql(u8, name, "paths")) {
                if (items[at + 3].tag != .period or items[at + 4].tag != .l_brace) return error.UnsupportedPackagePaths;
                at += 5;
                while (items[at].tag != .r_brace) : (at += 1) {
                    const value = items[at];
                    if (value.tag == .comma) continue;
                    if (value.tag != .string_literal) return error.UnsupportedPackagePaths;
                    const relative = try std.zig.string_literal.parseAlloc(self.allocator, bytes[value.loc.start..value.loc.end]);
                    if (std.fs.path.isAbsolute(relative)) return error.EscapingPackagePath;
                    const full = try std.fs.path.resolve(self.allocator, &.{ source, relative });
                    if (!std.mem.startsWith(u8, full, source) or (full.len > source.len and full[source.len] != '/')) return error.EscapingPackagePath;
                    try included.append(self.allocator, relative);
                }
            }
        }
        if (included.items.len == 0) return error.MissingPackagePaths;
        try manifest.writer.writeAll(bytes[copied..]);
        const staging = try std.fmt.allocPrint(self.allocator, "{s}/staging-{d}", .{ self.root, id });
        try std.Io.Dir.cwd().createDirPath(self.init.io, staging);
        var tar: std.ArrayList([]const u8) = .empty;
        try tar.appendSlice(self.allocator, &.{ "tar", "-cf", "-", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=zig-pkg", "--exclude=.git", "-C", source });
        // A disk archive keeps large generated packages out of the runner's heap.
        const snapshot = try std.fmt.allocPrint(self.allocator, "{s}/source-{d}.tar", .{ self.root, id });
        tar.items[2] = snapshot;
        try tar.appendSlice(self.allocator, included.items);
        _ = try self.run(tar.items, null);
        _ = try self.run(&.{ "tar", "-xf", snapshot, "-C", staging }, null);
        try std.Io.Dir.cwd().writeFile(self.init.io, .{ .sub_path = try std.fs.path.join(self.allocator, &.{ staging, "build.zig.zon" }), .data = manifest.written() });
        _ = try self.run(&.{ "tar", "-czf", destination, "-C", staging, "." }, null);
        const fetched = try self.run(&.{ "zig", "fetch", destination }, null);
        const hash = std.mem.trim(u8, fetched, " \t\r\n");
        if (hash.len == 0 or std.mem.indexOfScalar(u8, hash, '\n') != null) return error.InvalidPackageHash;
        const result: Archive = .{ .path = destination, .hash = hash };
        self.packages.getPtr(source).?.* = result;
        std.debug.print("Packaged {s}: {s}\n", .{ std.fs.path.basename(source), hash });
        return result;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len > 2) return error.ExpectedOptionalSourceDirectory;
    const source = if (args.len == 2) args[1] else "e2e/tests/protocol-extension";
    const root = try std.fs.path.resolve(allocator, &.{try std.fmt.allocPrint(allocator, ".zig-cache/package-distribution-{d}", .{std.Io.Clock.now(.awake, init.io).nanoseconds})});
    try std.Io.Dir.cwd().createDirPath(init.io, root);
    defer std.Io.Dir.cwd().deleteTree(init.io, root) catch {};
    var packager: Packager = .{ .init = init, .allocator = allocator, .root = root, .packages = std.StringHashMap(Archive).init(allocator) };
    const archive = try packager.archive(source);
    const consumer = try std.fs.path.join(allocator, &.{ root, "consumer" });
    try std.Io.Dir.cwd().createDirPath(init.io, consumer);
    _ = try packager.run(&.{ "tar", "-xzf", archive.path, "-C", consumer }, null);
    _ = try packager.run(&.{ "zig", "build" }, consumer);
    std.debug.print("Isolated downstream build passed with {d} packages.\n", .{packager.packages.count()});
}
