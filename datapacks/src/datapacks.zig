const std = @import("std");
const patterns = @import("pattern.zig");
const pack_metadata = @import("metadata.zig");
pub const Version = pack_metadata.Version;
const assert = std.debug.assert;

pub const Limits = struct {
    packs: usize = 256,
    resources: usize = 65536,
    resource_bytes: usize = 16 * 1024 * 1024,
    metadata_bytes: usize = 64 * 1024,
    total_bytes: usize = 128 * 1024 * 1024,
};

pub const Resource = struct {
    name: []const u8,
    bytes: []const u8,
    pack: usize,
    previous: ?usize,
    format: ?Version = null,
};

pub const Source = union(enum) { directory: []const u8, zip: []const u8, collection: []const u8 };

pub const Resources = struct {
    entries: []const Resource,
    packs: []const []const u8,
    index: std.StringHashMapUnmanaged(usize),
    directories: std.StringHashMapUnmanaged([]const usize),
    excluded: []const []const u8 = &.{},

    pub fn get(self: *const Resources, name: []const u8) ?*const Resource {
        return &self.entries[self.index.get(name) orelse return null];
    }

    pub fn layers(self: *const Resources, name: []const u8) Layers {
        return .{ .resources = self, .next_index = self.index.get(name) };
    }

    pub fn directory(self: *const Resources, name: []const u8) []const usize {
        return self.directories.get(name) orelse &.{};
    }

    pub const Layers = struct {
        resources: *const Resources,
        next_index: ?usize,

        pub fn next(self: *Layers) ?*const Resource {
            const entry = &self.resources.entries[self.next_index orelse return null];
            self.next_index = entry.previous;
            return entry;
        }
    };
};

pub const Archive = struct {
    version: Version,
    remaining: u32,
    reader: std.Io.Reader,
    pub const Entry = struct { name: []const u8, bytes: []const u8 };

    pub fn init(bytes: []const u8) !Archive {
        var reader = std.Io.Reader.fixed(bytes);
        if (!std.mem.eql(u8, try reader.take(8), "LRPACK02")) return error.InvalidPackArchive;
        const version: Version = .{ .major = try reader.takeInt(u32, .big), .minor = try reader.takeInt(u32, .big) };
        const remaining = try reader.takeInt(u32, .big);
        return .{ .version = version, .remaining = remaining, .reader = reader };
    }

    pub fn next(self: *Archive) !?Entry {
        if (self.remaining == 0) {
            if (self.reader.seek != self.reader.end) return error.InvalidPackArchive;
            return null;
        }
        const name = try self.reader.take(try self.reader.takeInt(u16, .big));
        const bytes = try self.reader.take(try self.reader.takeInt(u32, .big));
        self.remaining -= 1;
        return .{ .name = name, .bytes = bytes };
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    temporary: std.mem.Allocator,
    entries: std.ArrayList(Resource) = .empty,
    packs: std.ArrayList([]const u8) = .empty,
    index: std.StringHashMapUnmanaged(usize) = .empty,
    bytes: usize = 0,
    sealed: bool = false,
    target: ?Version = null,
    formats: []const Version = &.{},
    selected_format: ?Version = null,
    layer_start: usize = 0,
    filters: std.ArrayList(pack_metadata.Filter) = .empty,
    excluded: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator, temporary: std.mem.Allocator, limits: Limits) Builder {
        return .{ .allocator = allocator, .temporary = temporary, .limits = limits };
    }

    pub fn begin(self: *Builder, name: []const u8) !void {
        assert(!self.sealed);
        if (self.packs.items.len == self.limits.packs) return error.PackCapacity;
        if (name.len == 0 or name.len > 1024) return error.InvalidPackName;
        for (self.packs.items) |previous| if (std.mem.eql(u8, previous, name)) return error.DuplicatePack;
        try self.packs.append(self.temporary, try self.allocator.dupe(u8, name));
        self.layer_start = self.entries.items.len;
        self.selected_format = self.target;
    }

    pub fn add(self: *Builder, name: []const u8, bytes: []const u8) !void {
        const previous = try self.validate(name, bytes);
        try self.insert(try self.allocator.dupe(u8, name), try self.allocator.dupe(u8, bytes), previous);
    }

    fn validate(self: *const Builder, name: []const u8, bytes: []const u8) !?usize {
        assert(!self.sealed and self.packs.items.len > 0);
        if (!validName(name)) return error.InvalidResourceName;
        if (self.entries.items.len == self.limits.resources) return error.ResourceCapacity;
        if (bytes.len > self.limits.resource_bytes or bytes.len > self.limits.total_bytes - self.bytes) return error.ResourceSizeLimit;
        const previous = self.index.get(name);
        if (previous) |at| if (self.entries.items[at].pack == self.packs.items.len - 1 and at >= self.layer_start) return error.DuplicateResource;
        return previous;
    }

    fn insert(self: *Builder, name: []const u8, bytes: []const u8, previous: ?usize) !void {
        assert(!self.sealed and self.packs.items.len > 0);
        assert(previous == self.index.get(name));
        const lower = if (previous) |at| if (self.entries.items[at].pack == self.packs.items.len - 1) self.entries.items[at].previous else previous else null;
        try self.entries.append(self.temporary, .{ .name = name, .bytes = bytes, .pack = self.packs.items.len - 1, .previous = lower, .format = self.selected_format });
        try self.index.put(self.temporary, name, self.entries.items.len - 1);
        self.bytes += bytes.len;
    }

    /// Resource names and values borrow the immutable archive for their lifetime.
    pub fn archive(self: *Builder, name: []const u8, bytes: []const u8) !void {
        assert(!self.sealed);
        var source = try Archive.init(bytes);
        if (self.target) |selected| {
            if (selected.order(source.version) != .eq) return error.IncompatiblePackFormat;
        }
        if (self.formats.len > 0) {
            const supported = for (self.formats) |format| {
                if (format.order(source.version) == .eq) break true;
            } else false;
            if (!supported) return error.IncompatiblePackFormat;
        }
        if (source.remaining > self.limits.resources - self.entries.items.len) return error.ResourceCapacity;
        try self.begin(name);
        self.selected_format = source.version;
        while (try source.next()) |entry| {
            const previous = try self.validate(entry.name, entry.bytes);
            try self.insert(entry.name, entry.bytes, previous);
        }
    }

    pub fn inherit(self: *Builder, resources: *const Resources, borrowed: []const u8) !void {
        assert(!self.sealed and self.entries.items.len == 0 and self.packs.items.len == 0);
        if (resources.packs.len > self.limits.packs) return error.PackCapacity;
        if (resources.entries.len > self.limits.resources) return error.ResourceCapacity;
        for (resources.packs) |name| try self.packs.append(self.temporary, try self.allocator.dupe(u8, name));
        for (resources.entries) |entry| {
            if (entry.bytes.len > self.limits.resource_bytes or entry.bytes.len > self.limits.total_bytes - self.bytes) return error.ResourceSizeLimit;
            var copy = entry;
            copy.name = try self.copyBytes(entry.name, borrowed);
            copy.bytes = try self.copyBytes(entry.bytes, borrowed);
            try self.entries.append(self.temporary, copy);
            self.bytes = try std.math.add(usize, self.bytes, copy.bytes.len);
        }
        var iterator = resources.index.iterator();
        while (iterator.next()) |entry| try self.index.put(self.temporary, self.entries.items[entry.value_ptr.*].name, entry.value_ptr.*);
        for (resources.excluded) |name| try self.excluded.put(self.temporary, try self.allocator.dupe(u8, name), {});
        self.layer_start = self.entries.items.len;
    }

    fn copyBytes(self: *Builder, bytes: []const u8, borrowed: []const u8) ![]const u8 {
        const start = @intFromPtr(bytes.ptr);
        const base = @intFromPtr(borrowed.ptr);
        if (start >= base and start - base <= borrowed.len and bytes.len <= borrowed.len - (start - base)) return bytes;
        return self.allocator.dupe(u8, bytes);
    }

    pub fn directory(self: *Builder, io: std.Io, path: []const u8) !void {
        assert(!self.sealed);
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        const metadata_bytes = try dir.readFileAlloc(io, "pack.mcmeta", self.temporary, .limited(@min(self.limits.metadata_bytes, self.limits.resource_bytes)));
        const descriptor = try pack_metadata.Metadata.parse(self.temporary, metadata_bytes);
        const selected = self.target orelse if (self.formats.len > 0) try descriptor.select(self.formats) else descriptor.defaultVersion();
        const roots = try descriptor.roots(self.temporary, selected);
        try self.begin(path);
        self.selected_format = selected;
        try self.filter(descriptor.filters);
        var walker = try dir.walk(self.temporary);
        defer walker.deinit();
        var files: std.ArrayList([]const u8) = .empty;
        while (try walker.next(io)) |entry| {
            if (entry.kind == .sym_link) return error.PackSymlink;
            if (entry.kind != .file) continue;
            if (files.items.len == self.limits.resources) return error.ResourceCapacity;
            try files.append(self.temporary, try self.temporary.dupe(u8, entry.path));
        }
        std.mem.sortUnstable([]const u8, files.items, {}, lessName);
        for (roots) |root| {
            self.layer_start = self.entries.items.len;
            for (files.items) |file| {
                if (!std.mem.startsWith(u8, file, root)) continue;
                const name = try resourceName(self.temporary, file[root.len - "data/".len ..]);
                const data = try dir.readFileAlloc(io, file, self.temporary, .limited(@min(self.limits.resource_bytes, self.limits.total_bytes - self.bytes)));
                try self.add(name, data);
            }
        }
    }

    fn filter(self: *Builder, filters: []pack_metadata.Filter) !void {
        try self.filters.appendSlice(self.temporary, filters);
        var removed: std.ArrayList([]const u8) = .empty;
        var names = self.index.keyIterator();
        while (names.next()) |name| for (filters) |*rule| {
            if (rule.matches(name.*)) {
                try removed.append(self.temporary, name.*);
                break;
            }
        };
        for (removed.items) |name| {
            const removed_resource = self.index.remove(name);
            assert(removed_resource);
        }
    }

    pub fn exclude(self: *Builder, names: []const []const u8) !void {
        assert(!self.sealed);
        for (names) |name| {
            if (!validName(name)) return error.InvalidResourceName;
            for (self.filters.items) |*rule| {
                if (rule.matches(name)) {
                    const entry = try self.excluded.getOrPut(self.temporary, name);
                    if (!entry.found_existing) entry.key_ptr.* = try self.allocator.dupe(u8, name);
                    break;
                }
            }
        }
    }

    pub fn load(self: *Builder, io: std.Io, source: Source) !void {
        switch (source) {
            .directory => |path| try self.directory(io, path),
            .zip => |path| try self.zip(io, path),
            .collection => |path| try self.collection(io, path),
        }
    }

    pub fn collection(self: *Builder, io: std.Io, path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);
        const Pack = struct { path: []const u8, zip: bool };
        var packs: std.ArrayList(Pack) = .empty;
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind == .directory) {
                const metadata = try std.fmt.allocPrint(self.temporary, "{s}/pack.mcmeta", .{entry.name});
                dir.access(io, metadata, .{}) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
            } else if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zip")) continue;
            if (packs.items.len == self.limits.packs) return error.PackCapacity;
            try packs.append(self.temporary, .{ .path = try std.fs.path.join(self.temporary, &.{ path, entry.name }), .zip = entry.kind == .file });
        }
        std.mem.sortUnstable(Pack, packs.items, {}, struct {
            fn less(_: void, a: Pack, b: Pack) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.less);
        for (packs.items) |pack| if (pack.zip) try self.zip(io, pack.path) else try self.directory(io, pack.path);
    }

    pub fn zip(self: *Builder, io: std.Io, path: []const u8) !void {
        assert(!self.sealed);
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var buffer: [8192]u8 = undefined;
        var reader = file.reader(io, &buffer);
        var iterator = try std.zip.Iterator.init(&reader);
        const Entry = struct { name: []const u8, value: std.zip.Iterator.Entry };
        var entries: std.ArrayList(Entry) = .empty;
        var pack_header: ?std.zip.Iterator.Entry = null;
        while (try iterator.next()) |entry| {
            if (entry.filename_len > 4096) return error.InvalidResourceName;
            try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
            const name = try self.temporary.alloc(u8, entry.filename_len);
            try reader.interface.readSliceAll(name);
            if (std.mem.eql(u8, name, "pack.mcmeta")) {
                if (pack_header != null) return error.DuplicateResource;
                if (entry.uncompressed_size > self.limits.metadata_bytes) return error.ResourceSizeLimit;
                pack_header = entry;
                continue;
            }
            if (std.mem.endsWith(u8, name, "/")) continue;
            if (entries.items.len == self.limits.resources) return error.ResourceCapacity;
            try entries.append(self.temporary, .{ .name = name, .value = entry });
        }
        const header_bytes = try self.zipBytes(&reader, pack_header orelse return error.MissingPackMetadata);
        const descriptor = try pack_metadata.Metadata.parse(self.temporary, header_bytes);
        const selected = self.target orelse if (self.formats.len > 0) try descriptor.select(self.formats) else descriptor.defaultVersion();
        const roots = try descriptor.roots(self.temporary, selected);
        std.mem.sortUnstable(Entry, entries.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        try self.begin(path);
        self.selected_format = selected;
        try self.filter(descriptor.filters);
        for (roots) |root| {
            self.layer_start = self.entries.items.len;
            for (entries.items) |entry| {
                if (!std.mem.startsWith(u8, entry.name, root)) continue;
                if (entry.value.uncompressed_size > self.limits.total_bytes - self.bytes) return error.ResourceSizeLimit;
                const name = try resourceName(self.temporary, entry.name[root.len - "data/".len ..]);
                try self.add(name, try self.zipBytes(&reader, entry.value));
            }
        }
    }

    fn zipBytes(self: *Builder, reader: *std.Io.File.Reader, entry: std.zip.Iterator.Entry) ![]const u8 {
        if (entry.uncompressed_size > self.limits.resource_bytes or entry.compressed_size > self.limits.total_bytes) return error.ResourceSizeLimit;
        if (@as(u16, @bitCast(entry.flags)) & 1 != 0) return error.EncryptedPack;
        try reader.seekTo(entry.file_offset);
        const header = try reader.interface.takeStruct(std.zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &header.signature, &std.zip.local_file_header_sig) or header.filename_len != entry.filename_len or header.compression_method != entry.compression_method) return error.InvalidPackZip;
        const offset = try std.math.add(u64, entry.file_offset, @sizeOf(std.zip.LocalFileHeader) + @as(u64, header.filename_len) + header.extra_len);
        try reader.seekTo(offset);
        const compressed = try self.temporary.alloc(u8, @intCast(entry.compressed_size));
        try reader.interface.readSliceAll(compressed);
        const bytes = try self.temporary.alloc(u8, @intCast(entry.uncompressed_size));
        switch (entry.compression_method) {
            .store => {
                if (bytes.len != compressed.len) return error.InvalidPackZip;
                @memcpy(bytes, compressed);
            },
            .deflate => {
                var input = std.Io.Reader.fixed(compressed);
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var decompress: std.compress.flate.Decompress = .init(&input, .raw, &window);
                try decompress.reader.readSliceAll(bytes);
                if (decompress.reader.takeByte()) |_| return error.InvalidPackZip else |err| if (err != error.EndOfStream) return err;
            },
            else => return error.UnsupportedPackCompression,
        }
        if (std.hash.Crc32.hash(bytes) != entry.crc32) return error.InvalidPackChecksum;
        return bytes;
    }

    pub fn finish(self: *Builder) !Resources {
        assert(!self.sealed);
        var resources = try self.view();
        resources.entries = try self.allocator.dupe(Resource, self.entries.items);
        resources.packs = try self.allocator.dupe([]const u8, self.packs.items);
        resources.index = .empty;
        try resources.index.ensureTotalCapacity(self.allocator, self.index.count());
        var iterator = self.index.iterator();
        while (iterator.next()) |entry| resources.index.putAssumeCapacityNoClobber(entry.key_ptr.*, entry.value_ptr.*);
        self.sealed = true;
        return resources;
    }

    /// The view borrows builder storage until the next mutation.
    pub fn view(self: *const Builder) !Resources {
        var arena = std.heap.ArenaAllocator.init(self.temporary);
        defer arena.deinit();
        const temporary = arena.allocator();
        const selected = try temporary.alloc(usize, self.index.count());
        var values = self.index.valueIterator();
        var count: usize = 0;
        while (values.next()) |value| {
            selected[count] = value.*;
            count += 1;
        }
        std.mem.sortUnstable(usize, selected, self.entries.items, struct {
            fn less(entries: []const Resource, a: usize, b: usize) bool {
                return std.mem.lessThan(u8, entries[a].name, entries[b].name);
            }
        }.less);
        var lists: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
        for (selected) |index| {
            const name = self.entries.items[index].name;
            const path = name[std.mem.indexOfScalar(u8, name, ':').? + 1 ..];
            for (path, 0..) |character, end| {
                if (character != '/') continue;
                const entry = try lists.getOrPut(temporary, path[0..end]);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(temporary, index);
            }
        }
        var directories: std.StringHashMapUnmanaged([]const usize) = .empty;
        try directories.ensureTotalCapacity(self.allocator, lists.count());
        var iterator = lists.iterator();
        while (iterator.next()) |entry| directories.putAssumeCapacityNoClobber(entry.key_ptr.*, try self.allocator.dupe(usize, entry.value_ptr.items));
        const excluded = try self.allocator.alloc([]const u8, self.excluded.count());
        var names = self.excluded.keyIterator();
        var excluded_count: usize = 0;
        while (names.next()) |name| {
            excluded[excluded_count] = name.*;
            excluded_count += 1;
        }
        std.mem.sortUnstable([]const u8, excluded, {}, lessName);
        return .{ .entries = self.entries.items, .packs = self.packs.items, .index = self.index, .directories = directories, .excluded = excluded };
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 1024) return false;
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return false;
    if (colon == 0 or colon + 1 == name.len) return false;
    for (name[0..colon]) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-' and c != '.') return false;
    for (name[colon + 1 ..]) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-' and c != '.' and c != '/') return false;
    var segments = std.mem.splitScalar(u8, name[colon + 1 ..], '/');
    while (segments.next()) |segment| if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    return true;
}

pub fn identifier(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const result = if (std.mem.indexOfScalar(u8, name, ':') == null) try std.fmt.allocPrint(allocator, "minecraft:{s}", .{name}) else name;
    if (!validName(result)) return error.InvalidResourceName;
    return result;
}

test {
    _ = patterns;
}

fn resourceName(allocator: std.mem.Allocator, file: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, file, "data/")) return error.InvalidResourceName;
    const rest = file["data/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidResourceName;
    const name = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ rest[0..slash], rest[slash + 1 ..] });
    if (!validName(name)) return error.InvalidResourceName;
    return name;
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "resources retain pack precedence and source layers with owned bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = Builder.init(arena.allocator(), arena.allocator(), .{});
    try builder.begin("vanilla");
    try builder.add("minecraft:recipe/test.json", "original");
    try builder.begin("plugin");
    var bytes = [_]u8{'x'};
    try builder.add("minecraft:recipe/test.json", &bytes);
    bytes[0] = 'y';
    try std.testing.expectError(error.DuplicateResource, builder.add("minecraft:recipe/test.json", "again"));
    const resources = try builder.finish();
    try std.testing.expectEqualStrings("x", resources.get("minecraft:recipe/test.json").?.bytes);
    var layers = resources.layers("minecraft:recipe/test.json");
    try std.testing.expectEqualStrings("x", layers.next().?.bytes);
    try std.testing.expectEqualStrings("original", layers.next().?.bytes);
    try std.testing.expect(layers.next() == null);
}

test "resource names and size limits reject invalid content before preparation" {
    for ([_][]const u8{ "test:../escape", "test:/escape", "test:foo//bar", "Test:path", "test:path\\name", "missing" }) |name| try std.testing.expect(!validName(name));
    try std.testing.expect(validName("example:recipe/deep/path.json"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = Builder.init(arena.allocator(), arena.allocator(), .{ .total_bytes = 4 });
    try builder.begin("test");
    try builder.add("test:one", "1234");
    try std.testing.expectError(error.ResourceSizeLimit, builder.add("test:two", "5"));
}

test "directory and zip packs load identical resources with bounded decompression" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const metadata = "{\"pack\":{\"pack_format\":81,\"description\":\"test\"},\"overlays\":{\"entries\":[{\"formats\":81,\"directory\":\"v81\"}]}}";
    const recipe = "{\"test\":true}";
    const root_recipe = "{\"test\":false}";
    try directory.dir.createDirPath(io, "data/test/recipe");
    try directory.dir.writeFile(io, .{ .sub_path = "pack.mcmeta", .data = metadata });
    try directory.dir.writeFile(io, .{ .sub_path = "data/test/recipe/test.json", .data = root_recipe });
    try directory.dir.createDirPath(io, "v81/data/test/recipe");
    try directory.dir.writeFile(io, .{ .sub_path = "v81/data/test/recipe/test.json", .data = recipe });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var archive: std.Io.Writer.Allocating = .init(arena.allocator());
    var central: [3]std.zip.CentralDirectoryFileHeader = undefined;
    const names = [_][]const u8{ "pack.mcmeta", "data/test/recipe/test.json", "v81/data/test/recipe/test.json" };
    const values = [_][]const u8{ metadata, root_recipe, recipe };
    for (names, values, &central) |name, value, *entry| {
        const start = archive.written().len;
        var header = std.mem.zeroes(std.zip.LocalFileHeader);
        header.signature = std.zip.local_file_header_sig;
        header.version_needed_to_extract = 20;
        header.compression_method = .deflate;
        header.crc32 = std.hash.Crc32.hash(value);
        header.compressed_size = @intCast(value.len + 5);
        header.uncompressed_size = @intCast(value.len);
        header.filename_len = @intCast(name.len);
        try archive.writer.writeStruct(header, .little);
        try archive.writer.writeAll(name);
        try archive.writer.writeByte(1);
        try archive.writer.writeInt(u16, @intCast(value.len), .little);
        try archive.writer.writeInt(u16, ~@as(u16, @intCast(value.len)), .little);
        try archive.writer.writeAll(value);
        entry.* = std.mem.zeroes(std.zip.CentralDirectoryFileHeader);
        entry.signature = std.zip.central_file_header_sig;
        entry.version_needed_to_extract = 20;
        entry.compression_method = .deflate;
        entry.crc32 = header.crc32;
        entry.compressed_size = header.compressed_size;
        entry.uncompressed_size = header.uncompressed_size;
        entry.filename_len = header.filename_len;
        entry.local_file_header_offset = @intCast(start);
    }
    const central_start = archive.written().len;
    for (central, names) |entry, name| {
        try archive.writer.writeStruct(entry, .little);
        try archive.writer.writeAll(name);
    }
    var end = std.mem.zeroes(std.zip.EndRecord);
    end.signature = std.zip.end_record_sig;
    end.record_count_disk = 3;
    end.record_count_total = 3;
    end.central_directory_offset = @intCast(central_start);
    end.central_directory_size = @intCast(archive.written().len - central_start);
    try archive.writer.writeStruct(end, .little);
    try directory.dir.writeFile(io, .{ .sub_path = "test.zip", .data = archive.written() });
    const path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{directory.sub_path});
    const zip_path = try std.fmt.allocPrint(arena.allocator(), "{s}/test.zip", .{path});
    var folders = Builder.init(arena.allocator(), arena.allocator(), .{});
    try folders.directory(io, path);
    var zipped = Builder.init(arena.allocator(), arena.allocator(), .{});
    try zipped.zip(io, zip_path);
    const first = try folders.finish();
    const second = try zipped.finish();
    try std.testing.expectEqualStrings(recipe, first.get("test:recipe/test.json").?.bytes);
    try std.testing.expectEqualStrings(recipe, second.get("test:recipe/test.json").?.bytes);
    try std.testing.expectEqual(@as(u32, 81), first.get("test:recipe/test.json").?.format.?.major);
    try std.testing.expectEqual(@as(u32, 81), second.get("test:recipe/test.json").?.format.?.major);
    var inherited = Builder.init(arena.allocator(), arena.allocator(), .{});
    try inherited.inherit(&second, &.{});
    try inherited.begin("unversioned");
    try inherited.add("test:recipe/other.json", "new");
    const retained = try inherited.finish();
    try std.testing.expectEqual(@as(u32, 81), retained.get("test:recipe/test.json").?.format.?.major);
    try std.testing.expect(retained.get("test:recipe/other.json").?.format == null);
    var limited = Builder.init(arena.allocator(), arena.allocator(), .{ .resource_bytes = 1 });
    try std.testing.expectError(error.ResourceSizeLimit, limited.zip(io, zip_path));
}

test "pack filters remove lower layers and version overlays replace one pack layer" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const metadata_bytes =
        \\{"pack":{"pack_format":81,"supported_formats":[80,82],"description":"test"},"filter":{"block":[{"namespace":"test","path":"recipe/blocked\\.json"}]},"overlays":{"entries":[{"formats":81,"directory":"v81"},{"formats":82,"directory":"v82"}]}}
    ;
    try directory.dir.writeFile(io, .{ .sub_path = "pack.mcmeta", .data = metadata_bytes });
    for ([_][]const u8{ "data/test/recipe", "v81/data/test/recipe", "v82/data/test/recipe", "data/test/tags/item", "v81/data/test/tags/item" }) |path| try directory.dir.createDirPath(io, path);
    try directory.dir.writeFile(io, .{ .sub_path = "data/test/recipe/value.json", .data = "base" });
    try directory.dir.writeFile(io, .{ .sub_path = "v81/data/test/recipe/value.json", .data = "selected" });
    try directory.dir.writeFile(io, .{ .sub_path = "v82/data/test/recipe/value.json", .data = "other_version" });
    try directory.dir.writeFile(io, .{ .sub_path = "data/test/tags/item/values.json", .data = "{\"values\":[\"minecraft:stone\"]}" });
    try directory.dir.writeFile(io, .{ .sub_path = "v81/data/test/tags/item/values.json", .data = "{\"values\":[\"minecraft:dirt\"]}" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var builder = Builder.init(allocator, allocator, .{});
    builder.target = .{ .major = 81 };
    try builder.begin("native");
    try builder.add("test:recipe/blocked.json", "hidden");
    try builder.add("test:tags/item/values.json", "{\"values\":[\"minecraft:sand\"]}");
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{directory.sub_path});
    try builder.directory(io, path);
    const resources = try builder.finish();
    try std.testing.expect(resources.get("test:recipe/blocked.json") == null);
    try std.testing.expectEqualStrings("selected", resources.get("test:recipe/value.json").?.bytes);
    var tag_layers = resources.layers("test:tags/item/values.json");
    try std.testing.expect(tag_layers.next() != null);
    try std.testing.expect(tag_layers.next() != null);
    try std.testing.expect(tag_layers.next() == null);
    var negotiated = Builder.init(allocator, allocator, .{});
    negotiated.formats = &.{ .{ .major = 48 }, .{ .major = 71 }, .{ .major = 81 } };
    try negotiated.directory(io, path);
    const selected = try negotiated.finish();
    try std.testing.expectEqualStrings("selected", selected.get("test:recipe/value.json").?.bytes);
    try std.testing.expectEqual(@as(u32, 81), selected.get("test:recipe/value.json").?.format.?.major);
    var incompatible = Builder.init(allocator, allocator, .{});
    incompatible.target = .{ .major = 90 };
    try std.testing.expectError(error.IncompatiblePackFormat, incompatible.directory(io, path));
}

test "external exclusions survive finishing and inheriting without hiding replacement resources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var resources: Resources = undefined;
    {
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        var builder = Builder.init(allocator, scratch.allocator(), .{});
        try builder.begin("test:filters");
        const descriptor = try pack_metadata.Metadata.parse(scratch.allocator(),
            \\{"pack":{"pack_format":81,"description":"filters"},"filter":{"block":[{"namespace":"minecraft","path":"recipe/.*"}]}}
        );
        try builder.filter(descriptor.filters);
        try builder.add("minecraft:recipe/oak_planks.json", "replacement");
        const names = [_][]const u8{ "minecraft:recipe/oak_planks.json", "minecraft:recipe/stick.json", "test:recipe/custom.json" };
        try builder.exclude(&names);
        const view = try builder.view();
        try std.testing.expectEqual(@as(usize, 2), view.excluded.len);
        try std.testing.expect(view.get(names[0]) != null);
        resources = try builder.finish();
    }
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var inherited = Builder.init(allocator, scratch.allocator(), .{});
    try inherited.inherit(&resources, &.{});
    const result = try inherited.finish();
    try std.testing.expectEqual(@as(usize, 2), result.excluded.len);
    try std.testing.expectEqualStrings("minecraft:recipe/oak_planks.json", result.excluded[0]);
    try std.testing.expectEqualStrings("minecraft:recipe/stick.json", result.excluded[1]);
    try std.testing.expectEqualStrings("replacement", result.get(result.excluded[0]).?.bytes);
}
