//! Copy-on-write B+tree. Published pages are immutable. Transaction-private pages may be rewritten
//! until their buffer is flushed.
const std = @import("std");
const page = @import("index_page.zig");

pub const PageId = page.PageId;
pub const page_size = page.page_size;
pub const max_depth = 16;

/// Four maximum-size entries fit, including their directories. This bounds
/// either side of a byte-balanced split when a child adds two separators.
pub const max_key_bytes = (page_size - 16) / 4 - 22;

pub const Location = page.Location;

pub const Root = struct {
    page: PageId = 0,
    count: u64 = 0,
};

pub const Operation = union(enum) {
    put: Location,
    delete: void,
};

pub const Mutation = struct {
    namespace: []const u8,
    key: []const u8,
    operation: Operation,
};

pub const Applied = struct {
    root: Root,
    consumed: usize,
};

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

pub const Origin = enum { staged, disk };

/// Reads see staged writes. Replacing a published page must allocate a new ID. Only
/// transaction-private pages may retain their ID after a write.
pub const Io = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque, id: PageId, out: *[page_size]u8) ReadError!Origin,
    write_fn: *const fn (context: *anyopaque, previous: PageId, bytes: *const [page_size]u8) AppendError!PageId,

    fn read(self: Io, id: PageId, out: *[page_size]u8) Error!Origin {
        if (id == 0) return error.Corrupt;
        return self.read_fn(self.context, id, out) catch |err| return err;
    }

    fn write(self: Io, previous: PageId, bytes: *const [page_size]u8) Error!PageId {
        const id = self.write_fn(self.context, previous, bytes) catch |err| return err;
        if (id == 0) return error.IoFailure;
        return id;
    }
};

/// All temporary storage is caller-owned. An operation may overwrite it, and a cursor result
/// remains borrowed only until the cursor is advanced.
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
        const origin = try io.read(id, &self.path_pages[level]);
        const view = page.View.init(&self.path_pages[level], origin == .disk) catch return error.Corrupt;
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

/// Merges a sorted, unique prefix into one leaf and rewrites its ancestor path
/// once. The caller aborts on failure and publishes only after flushing buffers.
pub fn apply(io: Io, old_root: Root, workspace: *Workspace, mutations: []const Mutation) Error!Applied {
    defer workspace.reset();
    std.debug.assert(mutations.len != 0);

    for (mutations, 0..) |mutation, i| {
        try validateKey(mutation.namespace, mutation.key);

        if (i != 0) std.debug.assert(compare(mutations[i - 1].namespace, mutations[i - 1].key, mutation.namespace, mutation.key) == .lt);
    }

    const namespace = mutations[0].namespace;
    const key = mutations[0].key;
    if (old_root.page == 0 and old_root.count != 0) return error.Corrupt;
    if (old_root.page != 0 and old_root.count == 0) return error.Corrupt;
    if (old_root.page == 0) return .{ .consumed = 1, .root = switch (mutations[0].operation) {
        .delete => old_root,
        .put => |location| .{ .page = try makeSingleton(io, &workspace.output_a, namespace, key, location), .count = 1 },
    } };

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
    var fence: ?struct {
        namespace: []const u8,
        key: []const u8,
    } = null;
    var ancestor = depth;

    while (ancestor != 0) {
        ancestor -= 1;
        const view = workspace.path_views[ancestor];
        if (slots[ancestor] + 1 < view.count) {
            const next = view.entry(slots[ancestor] + 1).branch;
            fence = .{ .namespace = next.separator_namespace, .key = next.separator_key };
            break;
        }
    }

    var consumed: usize = 0;
    var inserted_bytes: usize = 0;

    for (mutations) |mutation| {
        if (fence) |limit| if (compare(mutation.namespace, mutation.key, limit.namespace, limit.key) != .lt) break;

        const bytes = if (mutation.operation == .put) 22 + mutation.namespace.len + mutation.key.len else 0;
        // A full leaf plus this prefix fits in at most two split pages.
        if (inserted_bytes + bytes > page_size / 2 - 16) break;
        inserted_bytes += bytes;
        consumed += 1;
    }

    std.debug.assert(consumed > 0);
    var changed = try rewriteLeaf(io, workspace.path_ids[depth], workspace.path_views[depth], &workspace.output_a, mutations[0..consumed]);
    const count = std.math.cast(u64, @as(i128, old_root.count) + changed.count_delta) orelse return error.Corrupt;

    var use_a = true;

    while (depth != 0) {
        depth -= 1;
        const outputs = if (use_a) &workspace.output_b else &workspace.output_a;
        changed = try rewriteBranch(io, workspace.path_ids[depth], workspace.path_views[depth], slots[depth], changed, outputs);
        use_a = !use_a;
    }

    if (changed.count == 0) return .{ .root = .{}, .consumed = consumed };

    if (changed.count == 1 and changed.kind == .branch and changed.pages[0].only_child != 0)
        return .{ .root = .{ .page = changed.pages[0].only_child, .count = count }, .consumed = consumed };

    if (changed.count != 1) {
        if (leaf_depth + 1 >= max_depth) return error.DepthExceeded;
        // The old root image is no longer needed after the upward rewrite.
        workspace.invalidate(0);
        var builder = page.Builder.init(&workspace.path_pages[0], .branch);
        var i: usize = 0;

        while (i < changed.count) : (i += 1) try appendBranch(&builder, changed.pages[i]);
        _ = builder.finish() catch return error.Corrupt;
        const new_id = try io.write(0, &workspace.path_pages[0]);
        return .{ .root = .{ .page = new_id, .count = count }, .consumed = consumed };
    }

    return .{ .root = .{ .page = changed.pages[0].id, .count = count }, .consumed = consumed };
}

const Produced = struct {
    id: PageId,
    namespace: []const u8,
    key: []const u8,
    only_child: PageId = 0,
};

const Change = struct {
    kind: page.Kind,
    previous: PageId = 0,
    pages: [2]Produced = undefined,
    count: usize = 0,
    count_delta: i64 = 0,
};

fn makeSingleton(io: Io, output: *[2][page_size]u8, namespace: []const u8, key: []const u8, location: Location) Error!PageId {
    var builder = page.Builder.init(&output[0], .leaf);
    try appendLeaf(&builder, namespace, key, location);
    _ = builder.finish() catch return error.Corrupt;
    return io.write(0, &output[0]);
}

fn rewriteLeaf(io: Io, previous: PageId, view: page.View, output: *[2][page_size]u8, mutations: []const Mutation) Error!Change {
    if (view.kind != .leaf) return error.Corrupt;

    var result: Change = .{ .kind = .leaf, .previous = previous };
    var bytes: usize = @as(usize, view.data_end) + @as(usize, view.count) * 2;

    for (mutations) |mutation| {
        const bound = view.lowerBound(mutation.namespace, mutation.key);

        if (bound < view.count) {
            const old = view.entry(bound).leaf;

            if (compare(old.namespace, old.key, mutation.namespace, mutation.key) == .eq) {
                bytes -= 22 + old.namespace.len + old.key.len;
                result.count_delta -= 1;
            }
        }

        if (mutation.operation == .put) {
            bytes += 22 + mutation.namespace.len + mutation.key.len;
            result.count_delta += 1;
        }
    }

    const split = bytes > page_size;
    var builder = page.Builder.init(&output[0], .leaf);
    var output_number: usize = 0;
    var i: u16 = 0;
    var m: usize = 0;

    while (i < view.count or m < mutations.len) {
        const order: std.math.Order = if (m == mutations.len) .lt else if (i == view.count) .gt else compare(view.entry(i).leaf.namespace, view.entry(i).leaf.key, mutations[m].namespace, mutations[m].key);

        if (order == .lt) {
            const entry = view.entry(i).leaf;
            try appendLeafSplit(io, &builder, output, &output_number, entry.namespace, entry.key, entry.location, &result, split);
            i += 1;
        } else {
            const mutation = mutations[m];

            if (mutation.operation == .put)
                try appendLeafSplit(io, &builder, output, &output_number, mutation.namespace, mutation.key, mutation.operation.put, &result, split);

            if (order == .eq) i += 1;
            m += 1;
        }
    }

    if (builder.count != 0) try finishLeaf(io, &builder, output_number, &result);
    return result;
}

fn rewriteBranch(io: Io, previous: PageId, view: page.View, replaced: u16, change: Change, output: *[2][page_size]u8) Error!Change {
    if (view.kind != .branch or replaced >= view.count) return error.Corrupt;

    const old = view.entry(replaced).branch;
    var bytes: usize = @as(usize, view.data_end) + @as(usize, view.count) * 2 - (14 + old.separator_namespace.len + old.separator_key.len);

    for (change.pages[0..change.count]) |item| bytes += 14 + item.namespace.len + item.key.len;
    const split = bytes > page_size;
    var result: Change = .{ .kind = .branch, .previous = previous, .count_delta = change.count_delta };
    var builder = page.Builder.init(&output[0], .branch);
    var output_number: usize = 0;
    var i: u16 = 0;

    while (i < view.count) : (i += 1) {
        if (i == replaced) {
            var j: usize = 0;

            while (j < change.count) : (j += 1) try appendBranchSplit(io, &builder, output, &output_number, change.pages[j], &result, split);
        } else {
            const entry = view.entry(i).branch;
            try appendBranchSplit(io, &builder, output, &output_number, .{
                .id = entry.child,
                .namespace = entry.separator_namespace,
                .key = entry.separator_key,
            }, &result, split);
        }
    }

    if (builder.count != 0) try finishBranch(io, &builder, output_number, &result);
    return result;
}

fn appendLeafSplit(io: Io, builder: *page.Builder, output: *[2][page_size]u8, output_number: *usize, namespace: []const u8, key: []const u8, location: Location, result: *Change, split: bool) Error!void {
    if (split and output_number.* == 0 and builder.cursor + @as(usize, builder.count) * 2 >= page_size / 2) {
        try finishLeaf(io, builder, output_number.*, result);
        output_number.* = 1;
        builder.* = page.Builder.init(&output[1], .leaf);
    }

    try appendLeaf(builder, namespace, key, location);
}

fn appendBranchSplit(io: Io, builder: *page.Builder, output: *[2][page_size]u8, output_number: *usize, item: Produced, result: *Change, split: bool) Error!void {
    if (split and output_number.* == 0 and builder.cursor + @as(usize, builder.count) * 2 >= page_size / 2) {
        try finishBranch(io, builder, output_number.*, result);
        output_number.* = 1;
        builder.* = page.Builder.init(&output[1], .branch);
    }

    try appendBranch(builder, item);
}

fn finishLeaf(io: Io, builder: *page.Builder, output_number: usize, result: *Change) Error!void {
    const view = builder.finish() catch return error.Corrupt;
    const id = try io.write(if (result.count == 0) result.previous else 0, builder.page);
    const first = view.entry(0).leaf;
    result.pages[result.count] = .{ .id = id, .namespace = first.namespace, .key = first.key };
    result.count += 1;
    _ = output_number;
}

fn finishBranch(io: Io, builder: *page.Builder, output_number: usize, result: *Change) Error!void {
    const view = builder.finish() catch return error.Corrupt;
    const id = try io.write(if (result.count == 0) result.previous else 0, builder.page);
    const first = view.entry(0).branch;
    result.pages[result.count] = .{
        .id = id,
        .namespace = first.separator_namespace,
        .key = first.separator_key,
        .only_child = if (view.count == 1) first.child else 0,
    };
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
    if (key.len == 0) return error.InvalidKey;

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

/// Ordered, bounded-memory read cursor. `seek` positions at the first key at or after its argument.
/// Calling `next` advances and returns the following entry.
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
                // This index represents emptiness exclusively as Root.page == zero. A referenced
                // empty leaf would otherwise make the descent below call entry(0) on a structurally
                // valid page.
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

    /// Ascending point lookups share the current leaf. Large gaps seek directly
    /// instead of scanning unrelated records between requested keys.
    pub fn lookupSorted(self: *Cursor, namespace: []const u8, key: []const u8) Error!?Location {
        try validateKey(namespace, key);
        if (self.valid) {
            const last = self.leaf_view.entry(self.leaf_view.count - 1).leaf;
            if (compare(namespace, key, last.namespace, last.key) != .gt) {
                while (self.leaf_at < self.leaf_view.count) : (self.leaf_at += 1) {
                    const item = self.leaf_view.entry(self.leaf_at).leaf;
                    const order = compare(item.namespace, item.key, namespace, key);
                    if (order == .lt) continue;
                    return if (order == .eq) item.location else null;
                }

                return null;
            }
        }

        const item = try self.seek(namespace, key) orelse return null;
        return if (compare(item.namespace, item.key, namespace, key) == .eq) item.location else null;
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

pub const Entry = struct {
    namespace: []const u8,
    key: []const u8,
    location: Location,
};
