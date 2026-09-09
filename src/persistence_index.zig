//! Immutable, append-only B+tree pages for the persistence store.
//!
//! `Root` is the complete durable handle: a caller must persist it atomically
//! after the pages appended by `apply`.  A zero page denotes the empty tree.
//! Pages are never changed, so an older Root remains readable after an update.
const std = @import("std");
const page = @import("persistence_index_page.zig");

pub const PageId = page.PageId;
pub const page_size = page.page_size;
pub const max_depth = 16;

/// The largest combined namespace and key length accepted by this tree.
/// It deliberately permits *three* branch entries in one page (including
/// their directories).  Replacing a child can add one entry; a three-way
/// minimum lets the two resulting variable-size pages always be packed.
pub const max_key_bytes = (page_size - 16) / 3 - (12 + 2);

/// Kept wire-identical to `persistence_index_page.Location` without importing
/// the higher-level persistence module (which would create an import cycle).
pub const Location = page.Location;
pub const Root = struct { page: PageId = 0, count: u64 = 0 };
pub const Operation = union(enum) { put: Location, delete: void };

pub const Error = error{
    Corrupt,
    InvalidKey,
    KeyTooLarge,
    DepthExceeded,
    PageFull,
    DiskFull,
    IoFailure,
};
pub const ReadError = error{IoFailure};
pub const AppendError = error{ DiskFull, IoFailure };

/// Appended pages must be readable immediately; the backend seals them before root publication.
pub const Io = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque, id: PageId, out: *[page_size]u8) ReadError!void,
    append_fn: *const fn (context: *anyopaque, bytes: *const [page_size]u8) AppendError!PageId,

    fn read(self: Io, id: PageId, out: *[page_size]u8) Error!void {
        if (id == 0) return error.Corrupt;
        self.read_fn(self.context, id, out) catch |err| return err;
    }
    fn append(self: Io, bytes: *const [page_size]u8) Error!PageId {
        const id = self.append_fn(self.context, bytes) catch |err| return err;
        if (id == 0) return error.IoFailure;
        return id;
    }
};

/// All temporary storage is caller-owned.  An operation may overwrite it, and
/// a cursor result remains borrowed only until the cursor is advanced.
pub const Workspace = struct {
    path_pages: [max_depth][page_size]u8 = undefined,
    path_views: [max_depth]page.View = undefined,
    path_ids: [max_depth]PageId = @splat(0),
    io_context: ?*anyopaque = null,
    output_a: [2][page_size]u8 = undefined,
    output_b: [2][page_size]u8 = undefined,

    pub fn reset(self: *Workspace) void {
        self.path_ids = @splat(0);
        self.io_context = null;
    }

    fn load(self: *Workspace, io: Io, level: usize, id: PageId) Error!page.View {
        if (self.io_context != io.context) {
            self.reset();
            self.io_context = io.context;
        }
        if (self.path_ids[level] == id) return self.path_views[level];
        self.path_ids[level] = 0;
        try io.read(id, &self.path_pages[level]);
        const view = page.View.init(&self.path_pages[level]) catch return error.Corrupt;
        self.path_views[level] = view;
        self.path_ids[level] = id;
        return view;
    }

    fn invalidate(self: *Workspace, level: usize) void {
        self.path_ids[level] = 0;
    }
};

pub fn lookup(io: Io, root: Root, workspace: *Workspace, namespace: []const u8, key: []const u8) Error!?Location {
    try validateKey(namespace, key);
    if (root.page == 0) return if (root.count == 0) null else error.Corrupt;
    if (root.count == 0) return error.Corrupt;
    var id = root.page;
    var level: usize = 0;
    while (true) {
        if (level == max_depth) return error.DepthExceeded;
        const view = try workspace.load(io, level, id);
        switch (view.kind) {
            .leaf => {
                if (view.count == 0) return error.Corrupt;
                const at = view.lowerBound(namespace, key);
                if (at == view.count) return null;
                const entry = view.entry(at).leaf;
                return if (compare(entry.namespace, entry.key, namespace, key) == .eq) entry.location else null;
            },
            .branch => {
                const at = branchChildIndex(view, namespace, key);
                id = view.entry(at).branch.child;
                level += 1;
            },
        }
    }
}

/// Applies one replacement/removal and returns the new durable handle.  The
/// caller publishes the returned Root only after any required metadata write.
/// Failed calls never publish a candidate root, although append-only backends
/// can contain unreachable pages from a failed attempt.
pub fn apply(io: Io, old_root: Root, workspace: *Workspace, namespace: []const u8, key: []const u8, operation: Operation) Error!Root {
    try validateKey(namespace, key);
    if (old_root.page == 0 and old_root.count != 0) return error.Corrupt;
    if (old_root.page != 0 and old_root.count == 0) return error.Corrupt;
    if (old_root.page == 0) return switch (operation) {
        .delete => old_root,
        .put => |location| .{ .page = try makeSingleton(io, &workspace.output_a, namespace, key, location), .count = 1 },
    };

    var slots: [max_depth]u16 = undefined;
    var depth: usize = 0;
    var id = old_root.page;
    while (true) {
        if (depth == max_depth) return error.DepthExceeded;
        const view = try workspace.load(io, depth, id);
        switch (view.kind) {
            .leaf => {
                if (view.count == 0) return error.Corrupt;
                break;
            },
            .branch => {
                slots[depth] = branchChildIndex(view, namespace, key);
                id = view.entry(slots[depth]).branch.child;
                depth += 1;
            },
        }
    }

    const leaf_depth = depth;
    var changed = try rewriteLeaf(io, &workspace.path_pages[depth], &workspace.output_a, namespace, key, operation);
    if (!changed.found and operation == .delete) return old_root;
    const count: u64 = switch (operation) {
        .put => if (changed.found) old_root.count else std.math.add(u64, old_root.count, 1) catch return error.IoFailure,
        .delete => if (old_root.count == 0) return error.Corrupt else old_root.count - 1,
    };

    var use_a = true;
    while (depth != 0) {
        depth -= 1;
        const outputs = if (use_a) &workspace.output_b else &workspace.output_a;
        changed = try rewriteBranch(io, &workspace.path_pages[depth], slots[depth], changed, outputs);
        use_a = !use_a;
    }
    if (changed.count == 0) return .{ .page = 0, .count = 0 };
    if (changed.count == 1 and changed.kind == .branch and changed.pages[0].only_child != 0) return .{ .page = changed.pages[0].only_child, .count = count };
    if (changed.count != 1) {
        // A split of the former root needs a new parent.  This is the only
        // point where the tree height grows.
        if (leaf_depth + 1 >= max_depth) return error.DepthExceeded;
        // The old root image is no longer needed after the upward rewrite.
        workspace.invalidate(0);
        var builder = page.Builder.init(&workspace.path_pages[0], .branch);
        var i: usize = 0;
        while (i < changed.count) : (i += 1) try appendBranch(&builder, changed.pages[i]);
        builder.finish() catch return error.Corrupt;
        const new_id = try io.append(&workspace.path_pages[0]);
        return .{ .page = new_id, .count = count };
    }
    return .{ .page = changed.pages[0].id, .count = count };
}

const Produced = struct {
    id: PageId,
    namespace: []const u8,
    key: []const u8,
    only_child: PageId = 0,
};
const Change = struct {
    kind: page.Kind,
    pages: [2]Produced = undefined,
    count: usize = 0,
    found: bool = false,
};

fn makeSingleton(io: Io, output: *[2][page_size]u8, namespace: []const u8, key: []const u8, location: Location) Error!PageId {
    var builder = page.Builder.init(&output[0], .leaf);
    try appendLeaf(&builder, namespace, key, location);
    builder.finish() catch return error.Corrupt;
    return io.append(&output[0]);
}

fn rewriteLeaf(io: Io, source: *const [page_size]u8, output: *[2][page_size]u8, namespace: []const u8, key: []const u8, operation: Operation) Error!Change {
    const view = page.View.init(source) catch return error.Corrupt;
    if (view.kind != .leaf) return error.Corrupt;
    const bound = view.lowerBound(namespace, key);
    const found = bound < view.count and compare(view.entry(bound).leaf.namespace, view.entry(bound).leaf.key, namespace, key) == .eq;
    var result: Change = .{ .kind = .leaf, .found = found };
    var builder = page.Builder.init(&output[0], .leaf);
    var output_number: usize = 0;
    var i: u16 = 0;
    while (i <= view.count) : (i += 1) {
        if (i == bound) switch (operation) {
            .put => |location| try appendLeafSplit(io, &builder, output, &output_number, namespace, key, location, &result),
            .delete => {},
        };
        if (i == view.count) break;
        if (found and i == bound) continue;
        const entry = view.entry(i).leaf;
        try appendLeafSplit(io, &builder, output, &output_number, entry.namespace, entry.key, entry.location, &result);
    }
    if (builder.count != 0) try finishLeaf(io, &builder, output_number, &result);
    return result;
}

fn rewriteBranch(io: Io, source: *const [page_size]u8, replaced: u16, change: Change, output: *[2][page_size]u8) Error!Change {
    const view = page.View.init(source) catch return error.Corrupt;
    if (view.kind != .branch or replaced >= view.count) return error.Corrupt;
    var result: Change = .{ .kind = .branch, .found = change.found };
    var builder = page.Builder.init(&output[0], .branch);
    var output_number: usize = 0;
    var i: u16 = 0;
    while (i < view.count) : (i += 1) {
        if (i == replaced) {
            var j: usize = 0;
            while (j < change.count) : (j += 1) try appendBranchSplit(io, &builder, output, &output_number, change.pages[j], &result);
        } else {
            const entry = view.entry(i).branch;
            try appendBranchSplit(io, &builder, output, &output_number, .{ .id = entry.child, .namespace = entry.separator_namespace, .key = entry.separator_key }, &result);
        }
    }
    if (builder.count != 0) try finishBranch(io, &builder, output_number, &result);
    return result;
}

fn appendLeafSplit(io: Io, builder: *page.Builder, output: *[2][page_size]u8, output_number: *usize, namespace: []const u8, key: []const u8, location: Location, result: *Change) Error!void {
    appendLeaf(builder, namespace, key, location) catch |err| switch (err) {
        error.PageFull => {
            try finishLeaf(io, builder, output_number.*, result);
            output_number.* += 1;
            if (output_number.* >= 2) return error.Corrupt;
            builder.* = page.Builder.init(&output[output_number.*], .leaf);
            try appendLeaf(builder, namespace, key, location);
        },
        else => return err,
    };
}
fn appendBranchSplit(io: Io, builder: *page.Builder, output: *[2][page_size]u8, output_number: *usize, item: Produced, result: *Change) Error!void {
    appendBranch(builder, item) catch |err| switch (err) {
        error.PageFull => {
            try finishBranch(io, builder, output_number.*, result);
            output_number.* += 1;
            if (output_number.* >= 2) return error.Corrupt;
            builder.* = page.Builder.init(&output[output_number.*], .branch);
            try appendBranch(builder, item);
        },
        else => return err,
    };
}
fn finishLeaf(io: Io, builder: *page.Builder, output_number: usize, result: *Change) Error!void {
    builder.finish() catch return error.Corrupt;
    const id = try io.append(builder.page);
    const view = page.View.init(builder.page) catch return error.Corrupt;
    const first = view.entry(0).leaf;
    result.pages[result.count] = .{ .id = id, .namespace = first.namespace, .key = first.key };
    result.count += 1;
    _ = output_number;
}
fn finishBranch(io: Io, builder: *page.Builder, output_number: usize, result: *Change) Error!void {
    builder.finish() catch return error.Corrupt;
    const id = try io.append(builder.page);
    const view = page.View.init(builder.page) catch return error.Corrupt;
    const first = view.entry(0).branch;
    result.pages[result.count] = .{ .id = id, .namespace = first.separator_namespace, .key = first.separator_key, .only_child = if (view.count == 1) first.child else 0 };
    result.count += 1;
    _ = output_number;
}
fn appendLeaf(builder: *page.Builder, namespace: []const u8, key: []const u8, location: Location) Error!void {
    builder.appendLeaf(namespace, key, location) catch |err| return switch (err) {
        error.PageFull => error.PageFull,
        error.KeyTooLarge => error.KeyTooLarge,
        error.InvalidKey => error.InvalidKey,
        error.InvalidOrder => error.Corrupt,
    };
}
fn appendBranch(builder: *page.Builder, item: Produced) Error!void {
    try validateSeparator(item.namespace, item.key);
    builder.appendBranch(item.id, item.namespace, item.key) catch |err| return switch (err) {
        error.PageFull => error.PageFull,
        error.KeyTooLarge => error.KeyTooLarge,
        error.InvalidOrder => error.Corrupt,
    };
}
fn branchChildIndex(view: page.View, namespace: []const u8, key: []const u8) u16 {
    const bound = view.lowerBound(namespace, key);
    if (bound == view.count) return bound - 1;
    const candidate = view.entry(bound).branch;
    return if (compare(candidate.separator_namespace, candidate.separator_key, namespace, key) == .eq) bound else if (bound == 0) 0 else bound - 1;
}
fn validateKey(namespace: []const u8, key: []const u8) Error!void {
    if (namespace.len == 0 or key.len == 0) return error.InvalidKey;
    const combined = std.math.add(usize, namespace.len, key.len) catch return error.KeyTooLarge;
    if (namespace.len > std.math.maxInt(u16) or key.len > std.math.maxInt(u16) or combined > max_key_bytes) return error.KeyTooLarge;
}
fn validateSeparator(namespace: []const u8, key: []const u8) Error!void {
    const combined = std.math.add(usize, namespace.len, key.len) catch return error.KeyTooLarge;
    if (namespace.len > std.math.maxInt(u16) or key.len > std.math.maxInt(u16) or combined > max_key_bytes) return error.KeyTooLarge;
}
fn validateScanStart(namespace: []const u8, key: []const u8) Error!void {
    const combined = std.math.add(usize, namespace.len, key.len) catch return error.KeyTooLarge;
    if (namespace.len > std.math.maxInt(u16) or key.len > std.math.maxInt(u16) or combined > max_key_bytes) return error.KeyTooLarge;
}
fn compare(an: []const u8, ak: []const u8, bn: []const u8, bk: []const u8) std.math.Order {
    const namespace = std.mem.order(u8, an, bn);
    return if (namespace == .eq) std.mem.order(u8, ak, bk) else namespace;
}

/// Ordered, bounded-memory read cursor.  `seek` positions at the first key at
/// or after its argument; `next` advances and returns the following entry.
pub const Cursor = struct {
    io: Io,
    root: Root,
    workspace: *Workspace,
    slots: [max_depth]u16 = undefined,
    depth: usize = 0,
    leaf_at: u16 = 0,
    leaf_view: page.View = undefined,
    valid: bool = false,

    pub fn init(io: Io, root: Root, workspace: *Workspace) Cursor {
        return .{ .io = io, .root = root, .workspace = workspace };
    }
    pub fn seek(self: *Cursor, namespace: []const u8, key: []const u8) Error!?Entry {
        try validateScanStart(namespace, key);
        self.valid = false;
        if (self.root.page == 0) return if (self.root.count == 0) null else error.Corrupt;
        if (self.root.count == 0) return error.Corrupt;
        var id = self.root.page;
        self.depth = 0;
        while (true) {
            if (self.depth == max_depth) return error.DepthExceeded;
            const view = try self.workspace.load(self.io, self.depth, id);
            if (view.kind == .leaf) {
                // This index represents emptiness exclusively as Root.page ==
                // zero.  A referenced empty leaf would otherwise make the
                // descent below call entry(0) on a structurally valid page.
                if (view.count == 0) return error.Corrupt;
                self.leaf_view = view;
                self.leaf_at = view.lowerBound(namespace, key);
                self.valid = true;
                if (self.leaf_at < view.count) return try self.current();
                return self.advanceLeaf();
            }
            self.slots[self.depth] = branchChildIndex(view, namespace, key);
            id = view.entry(self.slots[self.depth]).branch.child;
            self.depth += 1;
        }
    }
    pub fn next(self: *Cursor) Error!?Entry {
        if (!self.valid) return null;
        self.leaf_at += 1;
        if (self.leaf_at < self.leaf_view.count) return try self.current();
        return self.advanceLeaf();
    }
    fn current(self: *Cursor) Error!Entry {
        if (self.leaf_at >= self.leaf_view.count) return error.Corrupt;
        const item = self.leaf_view.entry(self.leaf_at).leaf;
        return .{ .namespace = item.namespace, .key = item.key, .location = item.location };
    }
    fn advanceLeaf(self: *Cursor) Error!?Entry {
        var level = self.depth;
        while (level != 0) {
            level -= 1;
            const branch = self.workspace.path_views[level];
            if (self.slots[level] + 1 >= branch.count) continue;
            self.slots[level] += 1;
            var id = branch.entry(self.slots[level]).branch.child;
            var below = level + 1;
            while (true) {
                if (below == max_depth) return error.DepthExceeded;
                const view = try self.workspace.load(self.io, below, id);
                if (view.kind == .leaf) {
                    if (view.count == 0) return error.Corrupt;
                    self.depth = below;
                    self.leaf_view = view;
                    self.leaf_at = 0;
                    return try self.current();
                }
                self.slots[below] = 0;
                id = view.entry(0).branch.child;
                below += 1;
            }
        }
        self.valid = false;
        return null;
    }
};
pub const Entry = struct { namespace: []const u8, key: []const u8, location: Location };

const TestMemory = struct {
    pages: [][page_size]u8,
    used: usize = 0,
    reads: usize = 0,
    fail_read: bool = false,
    fail_append: bool = false,

    fn io(self: *TestMemory) Io {
        return .{ .context = self, .read_fn = read, .append_fn = append };
    }
    fn read(context: *anyopaque, id: PageId, output: *[page_size]u8) ReadError!void {
        const self: *TestMemory = @ptrCast(@alignCast(context));
        if (self.fail_read or id == 0 or id > self.used) return error.IoFailure;
        self.reads += 1;
        output.* = self.pages[id - 1];
    }
    fn append(context: *anyopaque, bytes: *const [page_size]u8) AppendError!PageId {
        const self: *TestMemory = @ptrCast(@alignCast(context));
        if (self.fail_append or self.used == self.pages.len) return error.DiskFull;
        self.pages[self.used] = bytes.*;
        self.used += 1;
        return @intCast(self.used);
    }
};

fn testKey(number: u32) [4]u8 {
    var key: [4]u8 = undefined;
    std.mem.writeInt(u32, &key, number, .big);
    return key;
}
fn testLocation(number: u32) Location {
    return .{ .pack = number, .offset = number, .length = number };
}

test "cow index shuffled large insert, snapshot, lookup, and ordered cursor" {
    const total = 8_193;
    const backing = try std.testing.allocator.alloc([page_size]u8, 40_000);
    defer std.testing.allocator.free(backing);
    var memory: TestMemory = .{ .pages = backing };
    var workspace: Workspace = .{};
    var order: [total]u32 = undefined;
    for (&order, 0..) |*value, index| value.* = @intCast(index);
    var random = std.Random.DefaultPrng.init(0x6c_72_69_78);
    var remaining = order.len;
    while (remaining > 1) {
        remaining -= 1;
        const other = random.random().uintLessThan(usize, remaining + 1);
        std.mem.swap(u32, &order[remaining], &order[other]);
    }

    var root: Root = .{};
    var snapshot: Root = .{};
    for (order, 0..) |number, index| {
        const key = testKey(number);
        root = try apply(memory.io(), root, &workspace, "n", &key, .{ .put = testLocation(number) });
        if (index == 511) snapshot = root;
    }
    try std.testing.expectEqual(@as(u64, total), root.count);
    for (0..total) |index| {
        const key = testKey(@intCast(index));
        const location = (try lookup(memory.io(), root, &workspace, "n", &key)).?;
        try std.testing.expectEqual(@as(u64, index), location.offset);
    }
    // This is an open/recovery-style read through a root captured before the
    // later appends; immutable pages must keep it valid.
    const snapshot_key = testKey(order[0]);
    try std.testing.expectEqual(@as(u64, order[0]), (try lookup(memory.io(), snapshot, &workspace, "n", &snapshot_key)).?.offset);

    var cursor = Cursor.init(memory.io(), root, &workspace);
    var entry = try cursor.seek("", "");
    var expected: u32 = 0;
    while (entry) |value| {
        const key = testKey(expected);
        try std.testing.expectEqualSlices(u8, &key, value.key);
        try std.testing.expectEqual(@as(u64, expected), value.location.offset);
        expected += 1;
        entry = try cursor.next();
    }
    try std.testing.expectEqual(@as(u32, total), expected);
}

test "cow index deletes physical entries, collapses root, and preserves failures" {
    const backing = try std.testing.allocator.alloc([page_size]u8, 8_000);
    defer std.testing.allocator.free(backing);
    var memory: TestMemory = .{ .pages = backing };
    var workspace: Workspace = .{};
    var root: Root = .{};
    for (0..300) |index| {
        const key = testKey(@intCast(index));
        root = try apply(memory.io(), root, &workspace, "n", &key, .{ .put = testLocation(@intCast(index)) });
    }
    const before_failure = root;
    memory.fail_append = true;
    const failure_key = testKey(999);
    try std.testing.expectError(error.DiskFull, apply(memory.io(), root, &workspace, "n", &failure_key, .{ .put = testLocation(999) }));
    memory.fail_append = false;
    try std.testing.expectEqual(before_failure.page, root.page);
    try std.testing.expectEqual(null, try lookup(memory.io(), root, &workspace, "n", &failure_key));
    for (0..300) |index| {
        const key = testKey(@intCast(index));
        root = try apply(memory.io(), root, &workspace, "n", &key, .delete);
    }
    try std.testing.expectEqual(@as(PageId, 0), root.page);
    try std.testing.expectEqual(@as(u64, 0), root.count);
}

test "cow index maximum legal composite keys split leaves and branches" {
    const backing = try std.testing.allocator.alloc([page_size]u8, 1_000);
    defer std.testing.allocator.free(backing);
    var memory: TestMemory = .{ .pages = backing };
    var workspace: Workspace = .{};
    var root: Root = .{};
    for (0..9) |index| {
        var key = [_]u8{'a'} ** (max_key_bytes - 1);
        key[key.len - 1] = @intCast('a' + index);
        root = try apply(memory.io(), root, &workspace, "n", &key, .{ .put = testLocation(@intCast(index)) });
    }
    for (0..9) |index| {
        var key = [_]u8{'a'} ** (max_key_bytes - 1);
        key[key.len - 1] = @intCast('a' + index);
        try std.testing.expectEqual(@as(u64, index), (try lookup(memory.io(), root, &workspace, "n", &key)).?.offset);
    }
}

test "cow index randomized reference updates and corruption rejection" {
    const backing = try std.testing.allocator.alloc([page_size]u8, 12_000);
    defer std.testing.allocator.free(backing);
    var memory: TestMemory = .{ .pages = backing };
    var workspace: Workspace = .{};
    var root: Root = .{};
    var model = [_]?u32{null} ** 64;
    var random = std.Random.DefaultPrng.init(0x63_6f_77_69_6e_64_65_78);
    for (0..1_000) |_| {
        const index = random.random().uintLessThan(usize, model.len);
        const key = testKey(@intCast(index));
        if (random.random().boolean()) {
            const value = random.random().int(u32);
            root = try apply(memory.io(), root, &workspace, "n", &key, .{ .put = testLocation(value) });
            model[index] = value;
        } else {
            root = try apply(memory.io(), root, &workspace, "n", &key, .delete);
            model[index] = null;
        }
        for (model, 0..) |maybe_value, check| {
            const check_key = testKey(@intCast(check));
            const found = try lookup(memory.io(), root, &workspace, "n", &check_key);
            if (maybe_value) |value| try std.testing.expectEqual(@as(u64, value), found.?.offset) else try std.testing.expect(found == null);
        }
    }
    if (root.page != 0) {
        memory.pages[root.page - 1][0] ^= 1;
        workspace.reset();
        const key = testKey(0);
        try std.testing.expectError(error.Corrupt, lookup(memory.io(), root, &workspace, "n", &key));
    }
    try std.testing.expectError(error.Corrupt, lookup(memory.io(), .{ .page = 0, .count = 1 }, &workspace, "n", "k"));
}

test "workspace reuses validated immutable lookup paths" {
    const backing = try std.testing.allocator.alloc([page_size]u8, 2_000);
    defer std.testing.allocator.free(backing);
    var memory: TestMemory = .{ .pages = backing };
    var workspace: Workspace = .{};
    var root: Root = .{};
    for (0..400) |number| {
        const key = testKey(@intCast(number));
        root = try apply(memory.io(), root, &workspace, "n", &key, .{ .put = testLocation(@intCast(number)) });
    }
    workspace.reset();
    memory.reads = 0;
    const first = testKey(200);
    _ = try lookup(memory.io(), root, &workspace, "n", &first);
    const cold_reads = memory.reads;
    try std.testing.expect(cold_reads != 0);
    _ = try lookup(memory.io(), root, &workspace, "n", &first);
    try std.testing.expectEqual(cold_reads, memory.reads);
    const neighbor = testKey(201);
    _ = try lookup(memory.io(), root, &workspace, "n", &neighbor);
    try std.testing.expectEqual(cold_reads, memory.reads);

    workspace.reset();
    memory.reads = 0;
    var cursor = Cursor.init(memory.io(), root, &workspace);
    _ = try cursor.seek("n", &first);
    const seek_reads = memory.reads;
    _ = try cursor.next();
    try std.testing.expectEqual(seek_reads, memory.reads);

    const replacement = testKey(200);
    root = try apply(memory.io(), root, &workspace, "n", &replacement, .{ .put = testLocation(999) });
    const reads_before_updated_lookup = memory.reads;
    try std.testing.expectEqual(@as(u64, 999), (try lookup(memory.io(), root, &workspace, "n", &replacement)).?.offset);
    try std.testing.expect(memory.reads > reads_before_updated_lookup);

    workspace.reset();
    memory.pages[root.page - 1][0] ^= 1;
    try std.testing.expectError(error.Corrupt, lookup(memory.io(), root, &workspace, "n", &replacement));
}

test "failed and corrupt page loads do not retain a previous page ID" {
    const backing = try std.testing.allocator.alloc([page_size]u8, 100);
    defer std.testing.allocator.free(backing);
    var memory: TestMemory = .{ .pages = backing };
    var workspace: Workspace = .{};
    const old_key = testKey(1);
    const old_root = try apply(memory.io(), .{}, &workspace, "n", &old_key, .{ .put = testLocation(1) });
    workspace.reset();
    _ = try lookup(memory.io(), old_root, &workspace, "n", &old_key);

    const new_key = testKey(2);
    const new_root = try apply(memory.io(), old_root, &workspace, "n", &new_key, .{ .put = testLocation(2) });
    memory.fail_read = true;
    try std.testing.expectError(error.IoFailure, lookup(memory.io(), new_root, &workspace, "n", &new_key));
    memory.fail_read = false;
    const reads_before_old_root = memory.reads;
    try std.testing.expectEqual(@as(u64, 1), (try lookup(memory.io(), old_root, &workspace, "n", &old_key)).?.offset);
    try std.testing.expect(memory.reads > reads_before_old_root);

    memory.pages[new_root.page - 1][0] ^= 1;
    try std.testing.expectError(error.Corrupt, lookup(memory.io(), new_root, &workspace, "n", &new_key));
    const reads_before_second_old_root = memory.reads;
    try std.testing.expectEqual(@as(u64, 1), (try lookup(memory.io(), old_root, &workspace, "n", &old_key)).?.offset);
    try std.testing.expect(memory.reads > reads_before_second_old_root);
}
