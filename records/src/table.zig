const blob = @import("blob.zig");
const std = @import("std");
const storage = @import("storage");

const assert = std.debug.assert;
const maximum_key = 64;
const node_header_size = 16;
const cell_header_size = 8;
const maximum_cells = (storage.page_size - node_header_size) / (cell_header_size + 1);
const maximum_depth = 16;
const maximum_batch = 192;
const maximum_sorted_batch = 4096;
const maximum_outputs = maximum_batch + 3;
const working_cells = maximum_cells * 3 + maximum_batch;
const inline_threshold = (storage.page_size - node_header_size) / 3 - cell_header_size - maximum_key;
const local_limit = (storage.page_size - node_header_size) * 2 / 3 - cell_header_size - maximum_key;
const maximum_local = storage.page_size - node_header_size - cell_header_size - maximum_key;

const Direct = struct {
    pages: usize,
    prefix: usize,

    fn layout(length: usize, prefix: usize) Direct {
        assert(prefix <= length);
        assert(prefix == 0 or prefix == length % storage.page_size);
        const remaining = length - prefix;
        return .{ .pages = remaining / storage.page_size + @intFromBool(remaining % storage.page_size != 0), .prefix = prefix };
    }
    fn bytes(self: Direct) usize {
        return self.pages * 8 + self.prefix;
    }
};

const DataBatch = struct {
    space: storage.Space,
    pages: *[storage.batch_size]storage.Page,
    writes: *[storage.batch_size]storage.Write,
    count: usize = 0,

    fn flush(self: *DataBatch) storage.Error!void {
        if (self.count == 0) return;
        try self.space.writePages(self.writes[0..self.count]);
        self.count = 0;
    }
    fn append(self: *DataBatch, id: storage.PageId, value: []const u8) storage.Error!void {
        assert(value.len <= storage.page_size);
        if (self.count == storage.batch_size) try self.flush();
        const page = &self.pages[self.count];
        @memset(page[value.len..], 0);
        @memcpy(page[0..value.len], value);
        self.writes[self.count] = .{ .id = id, .source = page };
        self.count += 1;
    }
};

const NodeBatch = struct {
    space: storage.Space,
    ids: *[storage.batch_size]storage.PageId,
    pages: *[storage.batch_size]storage.Page,
    count: usize = 0,

    fn read(self: *const NodeBatch, id: storage.PageId, destination: *storage.Page) storage.Error!void {
        try self.readMany(&.{.{ .id = id, .destination = destination }});
    }

    fn readMany(self: *const NodeBatch, reads: []const storage.Read) storage.Error!void {
        assert(reads.len <= storage.batch_size);
        var missing: [storage.batch_size]storage.Read = undefined;
        var count: usize = 0;
        for (reads) |request| {
            for (self.ids[0..self.count], self.pages[0..self.count]) |cached_id, *page| {
                if (cached_id == request.id) {
                    @memcpy(request.destination, page[request.offset..][0..request.destination.len]);
                    break;
                }
            } else {
                missing[count] = request;
                count += 1;
            }
        }
        try self.space.readPages(missing[0..count]);
    }

    fn write(self: *NodeBatch, writes: []const storage.Write) storage.Error!void {
        for (writes) |request| {
            var at = for (self.ids[0..self.count], 0..) |id, index| {
                if (id == request.id) break index;
            } else self.count;
            if (at == self.count) {
                if (self.count == self.ids.len) {
                    try self.flush();
                    at = 0;
                }
                self.ids[at] = request.id;
                self.count += 1;
            }
            self.pages[at] = request.source.*;
        }
    }

    fn discard(self: *NodeBatch, id: storage.PageId) void {
        for (self.ids[0..self.count], 0..) |cached_id, at| {
            if (cached_id != id) continue;
            self.count -= 1;
            self.ids[at] = self.ids[self.count];
            self.pages[at] = self.pages[self.count];
            return;
        }
    }

    fn flush(self: *NodeBatch) storage.Error!void {
        if (self.count == 0) return;
        var writes: [storage.batch_size]storage.Write = undefined;
        for (writes[0..self.count], self.ids[0..self.count], self.pages[0..self.count]) |*request, id, *page| request.* = .{ .id = id, .source = page };
        try self.space.writePages(writes[0..self.count]);
        self.count = 0;
    }
};

const ValueReads = struct {
    data: blob.ReadBatch,

    fn flush(self: *ValueReads) storage.Error!void {
        try self.data.flush();
    }

    fn append(self: *ValueReads, cell: *const Cell, destination: []u8) storage.Error!usize {
        if (destination.len < cell.length) return error.BufferTooSmall;
        if (cell.flags == 0) {
            @memcpy(destination[0..cell.length], cell.value);
            return cell.length;
        }
        if (cell.flags == 3) {
            const layout = Direct.layout(cell.length, cell.prefix);
            @memcpy(destination[0..layout.prefix], cell.value[layout.pages * 8 ..]);
            var offset = layout.prefix;
            for (0..layout.pages) |at| {
                const length = @min(storage.page_size, cell.length - offset);
                try self.data.append(@enumFromInt(std.mem.readInt(u64, cell.value[at * 8 ..][0..8], .little)), destination[offset..][0..length]);
                offset += length;
            }
            assert(offset == cell.length);
            return cell.length;
        }
        return self.data.appendBlob(@enumFromInt(cell.reference), cell.length, destination);
    }
};

pub const Get = struct { key: []const u8, destination: []u8 };
pub const Write = struct { key: []const u8, value: ?[]const u8 };
pub const ScanCursor = struct { after: []u8, after_len: usize = 0 };
pub const ScanEntry = struct { key: []u8, value: []u8, key_len: usize = 0, value_len: usize = 0 };
pub const ScanResult = struct { count: usize, more: bool };

const Cell = struct {
    key: [maximum_key]u8 = undefined,
    key_len: u8 = 0,
    value: []const u8 = &.{},
    length: u32 = 0,
    reference: u64 = 0,
    flags: u16 = 0,
    prefix: u16 = 0,

    fn bytes(self: *const Cell) usize {
        return 8 + @as(usize, self.key_len) + if (self.flags == 0 or self.flags == 3) self.value.len else @as(usize, 8);
    }
    fn keySlice(self: *const Cell) []const u8 {
        return self.key[0..self.key_len];
    }
};

const UpdateWorkspace = struct {
    path: [maximum_depth]storage.Page = undefined,
    cells: [working_cells]Cell = undefined,
    parent_cells: [maximum_cells]Cell = undefined,
    peer_cells: [2][maximum_cells]Cell = undefined,
    peer_pages: [2]storage.Page = undefined,
    descriptors: [maximum_batch][local_limit]u8 = undefined,
    pages: [storage.batch_size]storage.Page = undefined,
    writes: [storage.batch_size]storage.Write = undefined,
    children: [maximum_outputs]Cell = undefined,
};

const Node = struct {
    cells: []Cell = &.{},
    count: usize = 0,
    branch: bool = false,
    next: u64 = 0,

    fn decode(page: *const storage.Page, cells: []Cell) storage.Error!Node {
        if (!std.mem.eql(u8, page[0..4], "LRBT") or page[4] > 1 or page[5] != 1) return error.Corrupt;
        var self: Node = .{ .cells = cells, .count = std.mem.readInt(u16, page[6..8], .little), .branch = page[4] != 0, .next = std.mem.readInt(u64, page[8..16], .little) };
        if (self.count > maximum_cells or self.count > cells.len or (self.branch and self.next != 0)) return error.Corrupt;
        var at: usize = 16;
        for (self.cells[0..self.count], 0..) |*cell, index| {
            if (page.len - at < 8) return error.Corrupt;
            const key_len = std.mem.readInt(u16, page[at..][0..2], .little);
            const representation = std.mem.readInt(u16, page[at + 2 ..][0..2], .little);
            const flags = representation & 3;
            const prefix = representation >> 2;
            const length = std.mem.readInt(u32, page[at + 4 ..][0..4], .little);
            if (key_len == 0 or key_len > maximum_key or (self.branch != (flags == 2)) or (self.branch and length != 0) or (flags == 1 and length == 0)) return error.Corrupt;
            if ((flags != 3 and prefix != 0) or (flags == 3 and (length == 0 or prefix > length or (prefix != 0 and prefix != length % storage.page_size)))) return error.Corrupt;
            at += 8;
            const value_size: usize = if (flags == 0) length else if (flags == 3) Direct.layout(length, prefix).bytes() else 8;
            if ((flags == 0 or flags == 3) and value_size > maximum_local) return error.Corrupt;
            if (flags == 3 and Direct.layout(length, prefix).pages == 0) return error.Corrupt;
            if (key_len > page.len - at or value_size > page.len - at - key_len) return error.Corrupt;
            cell.* = .{ .key_len = @intCast(key_len), .flags = flags, .length = length, .prefix = prefix };
            @memcpy(cell.key[0..key_len], page[at..][0..key_len]);
            at += key_len;
            if (flags == 0 or flags == 3) cell.value = page[at..][0..value_size] else {
                cell.reference = std.mem.readInt(u64, page[at..][0..8], .little);
                if (cell.reference == 0) return error.Corrupt;
            }
            at += value_size;
            if (index != 0 and std.mem.order(u8, self.cells[index - 1].keySlice(), cell.keySlice()) != .lt) return error.Corrupt;
        }
        if (self.branch and self.count == 0) return error.Corrupt;
        return self;
    }
    fn encode(self: *const Node, begin: usize, end: usize, next: u64) storage.Page {
        var page: storage.Page = @splat(0);
        @memcpy(page[0..4], "LRBT");
        page[4] = @intFromBool(self.branch);
        page[5] = 1;
        std.mem.writeInt(u16, page[6..8], @intCast(end - begin), .little);
        std.mem.writeInt(u64, page[8..16], next, .little);
        var at: usize = 16;
        for (self.cells[begin..end]) |*cell| {
            assert(at + cell.bytes() <= page.len);
            std.mem.writeInt(u16, page[at..][0..2], cell.key_len, .little);
            std.mem.writeInt(u16, page[at + 2 ..][0..2], cell.flags | (cell.prefix << 2), .little);
            std.mem.writeInt(u32, page[at + 4 ..][0..4], cell.length, .little);
            at += 8;
            @memcpy(page[at..][0..cell.key_len], cell.keySlice());
            at += cell.key_len;
            if (cell.flags == 0 or cell.flags == 3) {
                @memcpy(page[at..][0..cell.value.len], cell.value);
                at += cell.value.len;
            } else {
                std.mem.writeInt(u64, page[at..][0..8], cell.reference, .little);
                at += 8;
            }
        }
        return page;
    }
    fn lowerBound(self: *const Node, key: []const u8) usize {
        var low: usize = 0;
        var high = self.count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (std.mem.order(u8, self.cells[middle].keySlice(), key) == .lt) low = middle + 1 else high = middle;
        }
        return low;
    }
    fn insert(self: *Node, at: usize, cell: Cell) void {
        assert(self.count < self.cells.len and at <= self.count);
        std.mem.copyBackwards(Cell, self.cells[at + 1 .. self.count + 1], self.cells[at..self.count]);
        self.cells[at] = cell;
        self.count += 1;
    }
    fn remove(self: *Node, at: usize) void {
        assert(at < self.count);
        std.mem.copyForwards(Cell, self.cells[at .. self.count - 1], self.cells[at + 1 .. self.count]);
        self.count -= 1;
    }
};

pub const Table = struct {
    space: storage.Space,
    directory: ?storage.PageId = null,
    root_offset: u16 = 0,

    pub fn init(space: storage.Space) Table {
        return .{ .space = space };
    }
    pub fn rooted(space: storage.Space, directory: storage.PageId, offset: u16) Table {
        assert(offset <= storage.page_size - 8);
        return .{ .space = space, .directory = directory, .root_offset = offset };
    }
    fn getRoot(self: Table) storage.Error!?storage.PageId {
        const directory = self.directory orelse return self.space.getRoot();
        var page: storage.Page = undefined;
        try self.space.readPages(&.{.{ .id = directory, .destination = &page }});
        const id = std.mem.readInt(u64, page[self.root_offset..][0..8], .little);
        return if (id == 0) null else @enumFromInt(id);
    }
    fn setRoot(self: Table, root: ?storage.PageId) storage.Error!void {
        const directory = self.directory orelse return self.space.setRoot(root);
        var page: storage.Page = undefined;
        try self.space.readPages(&.{.{ .id = directory, .destination = &page }});
        std.mem.writeInt(u64, page[self.root_offset..][0..8], if (root) |id| @intFromEnum(id) else 0, .little);
        try self.space.writePages(&.{.{ .id = directory, .source = &page }});
    }
    pub fn fail(self: Table) void {
        self.space.fail();
    }

    pub fn get(self: Table, key: []const u8, destination: []u8) storage.Error!?usize {
        if (key.len == 0 or key.len > maximum_key) return error.InvalidArgument;
        var id = try self.getRoot() orelse return null;
        var depth: usize = 0;
        var cells: [maximum_cells]Cell = undefined;
        var values: ValueReads = .{ .data = .{ .space = self.space } };
        while (depth < maximum_depth) : (depth += 1) {
            var page: storage.Page = undefined;
            try self.space.readPages(&.{.{ .id = id, .destination = &page }});
            const node = try Node.decode(&page, &cells);
            const at = node.lowerBound(key);
            if (node.branch) {
                id = @enumFromInt(node.cells[@min(at, node.count - 1)].reference);
                continue;
            }
            if (at == node.count or !std.mem.eql(u8, node.cells[at].keySlice(), key)) return null;
            const length = try values.append(&node.cells[at], destination);
            try values.flush();
            return length;
        }
        return error.Corrupt;
    }
    pub fn getBatch(self: Table, requests: []const Get, lengths: []?usize) storage.Error!void {
        if (requests.len != lengths.len) return error.InvalidArgument;
        @memset(lengths, null);
        for (requests) |request| if (request.key.len == 0 or request.key.len > maximum_key) return error.InvalidArgument;
        const root = try self.getRoot() orelse return;
        var values: ValueReads = .{ .data = .{ .space = self.space } };
        var pages: [storage.batch_size]storage.Page = undefined;
        var cells: [maximum_cells]Cell = undefined;
        var begin: usize = 0;
        while (begin < requests.len) {
            const count = @min(storage.batch_size, requests.len - begin);
            var ids: [storage.batch_size]storage.PageId = @splat(root);
            var active: [storage.batch_size]bool = @splat(true);
            var mapping: [storage.batch_size]usize = undefined;
            var unique: [storage.batch_size]storage.PageId = undefined;
            var reads: [storage.batch_size]storage.Read = undefined;
            var depth: usize = 0;
            while (true) : (depth += 1) {
                var reading: usize = 0;
                for (ids[0..count], active[0..count], mapping[0..count]) |id, live, *page| {
                    if (!live) continue;
                    var index: usize = 0;
                    while (index < reading and unique[index] != id) index += 1;
                    page.* = index;
                    if (index == reading) {
                        unique[reading] = id;
                        reads[reading] = .{ .id = id, .destination = &pages[reading] };
                        reading += 1;
                    }
                }
                if (reading == 0) break;
                if (depth == maximum_depth) return error.Corrupt;
                try self.space.readPages(reads[0..reading]);
                for (pages[0..reading], 0..) |*page, page_index| {
                    const node = try Node.decode(page, &cells);
                    for (requests[begin..][0..count], 0..) |request, index| {
                        if (!active[index] or mapping[index] != page_index) continue;
                        if (request.key.len == 0 or request.key.len > maximum_key) return error.InvalidArgument;
                        const position = node.lowerBound(request.key);
                        if (node.branch) {
                            ids[index] = @enumFromInt(node.cells[@min(position, node.count - 1)].reference);
                        } else {
                            active[index] = false;
                            if (position < node.count and std.mem.eql(u8, node.cells[position].keySlice(), request.key))
                                lengths[begin + index] = try values.append(&node.cells[position], request.destination);
                        }
                    }
                }
            }
            begin += count;
        }
        try values.flush();
    }
    fn freeValue(self: Table, cell: *const Cell) storage.Error!void {
        if (cell.flags == 1) try blob.free(self.space, @enumFromInt(cell.reference), cell.length);
        if (cell.flags == 3) {
            const layout = Direct.layout(cell.length, cell.prefix);
            var begin: usize = 0;
            while (begin < layout.pages) {
                const count = @min(storage.batch_size, layout.pages - begin);
                var ids: [storage.batch_size]storage.PageId = undefined;
                for (ids[0..count], 0..) |*id, at| id.* = @enumFromInt(std.mem.readInt(u64, cell.value[(begin + at) * 8 ..][0..8], .little));
                try self.space.freePages(ids[0..count]);
                begin += count;
            }
        }
    }
    fn makeCell(self: Table, key: []const u8, value: []const u8, occupied: usize, descriptor: *[local_limit]u8, data: *DataBatch) storage.Error!Cell {
        assert(occupied <= storage.page_size - node_header_size);
        if (key.len == 0 or key.len > maximum_key or value.len > std.math.maxInt(u32)) return error.InvalidArgument;
        var cell: Cell = .{ .key_len = @intCast(key.len), .length = @intCast(value.len), .value = value };
        @memcpy(cell.key[0..key.len], key);
        if (value.len > inline_threshold) {
            var layout = Direct.layout(value.len, value.len % storage.page_size);
            const header = cell_header_size + key.len;
            const available = storage.page_size - node_header_size - occupied;
            const spilled_bytes = header + (layout.pages + 1) * 8;
            // Either choice can consume one extra page. Keep the larger gap available
            // for following cells when spilling the remainder avoids a leaf split.
            if (layout.bytes() > local_limit or (header + layout.bytes() > available and
                layout.prefix > occupied + 8 and spilled_bytes <= available))
            {
                layout = Direct.layout(value.len, 0);
            }
            if (layout.pages == 0) return cell;
            if (layout.bytes() <= local_limit) {
                cell.flags = 3;
                cell.prefix = @intCast(layout.prefix);
                cell.value = descriptor[0..layout.bytes()];
                @memcpy(descriptor[layout.pages * 8 ..][0..layout.prefix], value[0..layout.prefix]);
                var begin: usize = 0;
                var offset = layout.prefix;
                while (begin < layout.pages) {
                    const count = @min(storage.batch_size, layout.pages - begin);
                    var ids: [storage.batch_size]storage.PageId = undefined;
                    try self.space.allocatePages(ids[0..count]);
                    for (ids[0..count], 0..) |id, at| {
                        std.mem.writeInt(u64, descriptor[(begin + at) * 8 ..][0..8], @intFromEnum(id), .little);
                        const length = @min(value.len - offset, storage.page_size);
                        try data.append(id, value[offset..][0..length]);
                        offset += length;
                    }
                    begin += count;
                }
                assert(offset == value.len);
            } else {
                cell.flags = 1;
                cell.reference = @intFromEnum(try blob.write(self.space, value));
            }
        }
        return cell;
    }

    pub fn put(self: Table, key: []const u8, value: ?[]const u8) storage.Error!void {
        try self.putBatch(&.{.{ .key = key, .value = value }});
    }
    pub fn putBatch(self: Table, writes: []const Write) storage.Error!void {
        if (writes.len == 0) return;
        errdefer self.fail();
        var ids: [storage.batch_size]storage.PageId = undefined;
        var pages: [storage.batch_size]storage.Page = undefined;
        var nodes: NodeBatch = .{ .space = self.space, .ids = &ids, .pages = &pages };
        var workspace: UpdateWorkspace = .{};
        var begin: usize = 0;
        while (begin < writes.len) {
            const count = @min(writes.len - begin, maximum_sorted_batch);
            const batch = writes[begin..][0..count];
            var order: [maximum_sorted_batch]u16 = undefined;
            var sorted: [maximum_batch]Write = undefined;
            for (batch, order[0..count], 0..) |write, *index, at| {
                if (write.key.len == 0 or write.key.len > maximum_key) return error.InvalidArgument;
                index.* = @intCast(at);
            }
            std.mem.sort(u16, order[0..count], batch, struct {
                fn less(items: []const Write, a: u16, b: u16) bool {
                    const result = std.mem.order(u8, items[a].key, items[b].key);
                    return if (result == .eq) a < b else result == .lt;
                }
            }.less);
            var at: usize = 0;
            while (at < count) {
                var unique: usize = 0;
                while (at < count and unique < sorted.len) {
                    const index = order[at];
                    at += 1;
                    if (at < count and std.mem.eql(u8, batch[index].key, batch[order[at]].key)) continue;
                    sorted[unique] = batch[index];
                    unique += 1;
                }
                var applied: usize = 0;
                while (applied < unique) applied += try self.update(sorted[applied..unique], &nodes, &workspace);
            }
            begin += count;
        }
        try nodes.flush();
    }

    fn update(self: Table, writes: []const Write, nodes: *NodeBatch, workspace: *UpdateWorkspace) storage.Error!usize {
        assert(writes.len != 0 and writes.len <= maximum_batch);
        const first = writes[0];
        const path = &workspace.path;
        var ids: [maximum_depth]storage.PageId = undefined;
        var positions: [maximum_depth]usize = undefined;
        var depth: usize = 0;
        var rightmost = true;
        const cells = &workspace.cells;
        const parent_cells = &workspace.parent_cells;
        const peer_cells = &workspace.peer_cells;
        const peer_pages = &workspace.peer_pages;
        if (try self.getRoot()) |root| ids[0] = root else {
            var missing: usize = 0;
            while (missing < writes.len and writes[missing].value == null) missing += 1;
            if (missing != 0) return missing;
            var allocated: [1]storage.PageId = undefined;
            try self.space.allocatePages(&allocated);
            ids[0] = allocated[0];
            const empty: Node = .{};
            path[0] = empty.encode(0, 0, 0);
            try nodes.write(&.{.{ .id = ids[0], .source = &path[0] }});
            try self.setRoot(ids[0]);
        }
        var node: Node = undefined;
        while (true) {
            try nodes.read(ids[depth], &path[depth]);
            node = try Node.decode(&path[depth], cells);
            positions[depth] = node.lowerBound(first.key);
            if (!node.branch) break;
            positions[depth] = @min(positions[depth], node.count - 1);
            if (positions[depth] + 1 != node.count) rightmost = false;
            if (depth + 1 == maximum_depth) return error.NoSpace;
            ids[depth + 1] = @enumFromInt(node.cells[positions[depth]].reference);
            depth += 1;
        }
        var height = depth + 1;
        const upper = if (node.count != 0) node.cells[node.count - 1] else null;
        var used: usize = 0;
        var changed = false;
        const descriptors = &workspace.descriptors;
        var data: DataBatch = .{ .space = self.space, .pages = &workspace.pages, .writes = &workspace.writes };
        var accounted: usize = 0;
        var leaf_bytes: usize = 0;
        for (writes) |write| {
            if (!rightmost and upper != null and std.mem.order(u8, write.key, upper.?.keySlice()) == .gt) break;
            const at = node.lowerBound(write.key);
            const exists = at < node.count and std.mem.eql(u8, node.cells[at].keySlice(), write.key);
            used += 1;
            if (exists and write.value != null and node.cells[at].flags == 0 and std.mem.eql(u8, node.cells[at].value, write.value.?)) continue;
            if (!exists and write.value == null) continue;
            if (exists) {
                try self.freeValue(&node.cells[at]);
                node.remove(at);
            }
            for (node.cells[accounted..at]) |*cell| {
                if (leaf_bytes + cell.bytes() > storage.page_size - node_header_size) leaf_bytes = 0;
                leaf_bytes += cell.bytes();
            }
            accounted = at;
            if (write.value) |value| {
                const cell = try self.makeCell(write.key, value, leaf_bytes, &descriptors[used - 1], &data);
                node.insert(at, cell);
                if (leaf_bytes + cell.bytes() > storage.page_size - node_header_size) leaf_bytes = 0;
                leaf_bytes += cell.bytes();
                accounted += 1;
            }
            changed = true;
        }
        assert(used != 0);
        if (!changed) return used;
        try data.flush();
        const children = &workspace.children;
        while (true) {
            if (depth == 0 and node.branch and node.count == 1) {
                const child: storage.PageId = @enumFromInt(node.cells[0].reference);
                try self.setRoot(child);
                nodes.discard(ids[0]);
                try self.space.freePages(&.{ids[0]});
                ids[0] = child;
                try nodes.read(child, &path[0]);
                node = try Node.decode(&path[0], cells);
                height -= 1;
                continue;
            }
            var old_ids: [3]storage.PageId = undefined;
            old_ids[0] = ids[depth];
            var replaced: usize = 1;
            var node_bytes: usize = node_header_size;
            for (node.cells[0..node.count]) |*cell| node_bytes += cell.bytes();
            if (depth != 0 and (node_bytes > storage.page_size or node_bytes < storage.page_size / 2)) {
                const parent = try Node.decode(&path[depth - 1], parent_cells);
                const at = positions[depth - 1];
                const first_peer = @min(at -| 1, parent.count -| 3);
                replaced = @min(parent.count, 3);
                var peers: [3]Node = undefined;
                var reading: usize = 0;
                var reads: [2]storage.Read = undefined;
                for (old_ids[0..replaced], 0..) |*id, index| {
                    const position = first_peer + index;
                    id.* = @enumFromInt(parent.cells[position].reference);
                    if (position == at) continue;
                    reads[reading] = .{ .id = id.*, .destination = &peer_pages[reading] };
                    reading += 1;
                }
                try nodes.readMany(reads[0..reading]);
                reading = 0;
                for (peers[0..replaced], 0..) |*peer, index| {
                    if (first_peer + index == at) {
                        peer.* = node;
                    } else {
                        peer.* = try Node.decode(&peer_pages[reading], &peer_cells[reading]);
                        reading += 1;
                        if (peer.branch != node.branch or peer.count == 0) return error.Corrupt;
                    }
                    if (!node.branch and index != 0 and peers[index - 1].next != @intFromEnum(old_ids[index])) return error.Corrupt;
                }
                var selected_begin: usize = 0;
                var selected_end: usize = replaced;
                var growth: isize = std.math.maxInt(isize);
                const pivot = at - first_peer;
                // Minimize page growth first, then the number of existing pages rewritten.
                for (0..pivot + 1) |begin| {
                    for (pivot + 1..replaced + 1) |end| {
                        if (end - begin == 1 and replaced > 1 and node_bytes < storage.page_size / 2) continue;
                        var required: usize = 1;
                        var occupied: usize = node_header_size;
                        for (peers[begin..end]) |peer| for (peer.cells[0..peer.count]) |*cell| {
                            if (occupied + cell.bytes() > storage.page_size) {
                                required += 1;
                                occupied = node_header_size;
                            }
                            occupied += cell.bytes();
                        };
                        const added = @as(isize, @intCast(required)) - @as(isize, @intCast(end - begin));
                        if (added < growth or (added == growth and end - begin < selected_end - selected_begin)) {
                            growth = added;
                            selected_begin = begin;
                            selected_end = end;
                        }
                    }
                }
                var prefix: usize = 0;
                var total: usize = 0;
                for (peers[selected_begin..selected_end], selected_begin..) |peer, index| {
                    if (index == pivot) prefix = total;
                    total += peer.count;
                }
                assert(total <= node.cells.len);
                std.mem.copyBackwards(Cell, node.cells[prefix .. prefix + node.count], node.cells[0..node.count]);
                var offset: usize = 0;
                for (peers[selected_begin..selected_end], selected_begin..) |peer, index| {
                    if (index != pivot) @memcpy(node.cells[offset..][0..peer.count], peer.cells[0..peer.count]);
                    offset += peer.count;
                }
                node.count = total;
                node.next = peers[selected_end - 1].next;
                std.mem.copyForwards(storage.PageId, old_ids[0 .. selected_end - selected_begin], old_ids[selected_begin..selected_end]);
                replaced = selected_end - selected_begin;
                ids[depth] = old_ids[0];
                positions[depth - 1] = first_peer + selected_begin;
            }
            var child_count: usize = 0;
            if (node.count == 0) {
                if (depth != 0 and !node.branch) {
                    var level = depth;
                    while (level != 0) {
                        level -= 1;
                        if (positions[level] == 0) continue;
                        const parent = try Node.decode(&path[level], parent_cells);
                        var predecessor: storage.PageId = @enumFromInt(parent.cells[positions[level] - 1].reference);
                        var preceding_page: storage.Page = undefined;
                        var steps: usize = 0;
                        while (true) {
                            try nodes.read(predecessor, &preceding_page);
                            var preceding = try Node.decode(&preceding_page, &peer_cells[0]);
                            if (!preceding.branch) {
                                if (preceding.next != @intFromEnum(ids[depth])) return error.Corrupt;
                                const page = preceding.encode(0, preceding.count, node.next);
                                try nodes.write(&.{.{ .id = predecessor, .source = &page }});
                                break;
                            }
                            if (steps == maximum_depth) return error.Corrupt;
                            steps += 1;
                            predecessor = @enumFromInt(preceding.cells[preceding.count - 1].reference);
                        }
                        break;
                    }
                }
                nodes.discard(ids[depth]);
                try self.space.freePages(&.{ids[depth]});
            } else {
                var boundaries: [maximum_outputs + 1]usize = undefined;
                var output_ids: [maximum_outputs]storage.PageId = undefined;
                const capacity = storage.page_size - node_header_size;
                var pages_needed: [working_cells + 1]u16 = undefined;
                pages_needed[node.count] = 0;
                var suffix_pages: u16 = 1;
                var suffix_bytes: usize = 0;
                var remaining_bytes: usize = 0;
                var cell_index = node.count;
                while (cell_index != 0) {
                    cell_index -= 1;
                    const bytes = node.cells[cell_index].bytes();
                    if (suffix_bytes + bytes > capacity) {
                        suffix_pages += 1;
                        suffix_bytes = 0;
                    }
                    suffix_bytes += bytes;
                    remaining_bytes += bytes;
                    pages_needed[cell_index] = suffix_pages;
                }
                child_count = pages_needed[0];
                if (child_count > output_ids.len) return error.Corrupt;
                boundaries[0] = 0;
                for (0..child_count) |child| {
                    const remaining_pages = child_count - child;
                    const first_cell = boundaries[child];
                    var prefix: usize = 0;
                    var selected_bytes: usize = 0;
                    var selected = first_cell;
                    var imbalance: usize = std.math.maxInt(usize);
                    // The suffix must still fit after choosing a balanced boundary.
                    for (node.cells[first_cell..node.count], first_cell + 1..) |*cell, at| {
                        prefix += cell.bytes();
                        if (prefix > capacity) break;
                        if (pages_needed[at] > remaining_pages - 1 or node.count - at < remaining_pages - 1) continue;
                        const weighted = prefix * remaining_pages;
                        const difference = @max(weighted, remaining_bytes) - @min(weighted, remaining_bytes);
                        if (difference <= imbalance) {
                            selected = at;
                            selected_bytes = prefix;
                            imbalance = difference;
                        }
                    }
                    assert(selected > first_cell);
                    boundaries[child + 1] = selected;
                    remaining_bytes -= selected_bytes;
                }
                assert(remaining_bytes == 0);
                const reused = @min(child_count, replaced);
                @memcpy(output_ids[0..reused], old_ids[0..reused]);
                try self.space.allocatePages(output_ids[reused..child_count]);
                for (old_ids[reused..replaced]) |id| nodes.discard(id);
                try self.space.freePages(old_ids[reused..replaced]);
                var begin: usize = 0;
                while (begin < child_count) {
                    const count = @min(storage.batch_size, child_count - begin);
                    const pages = &workspace.pages;
                    const output = &workspace.writes;
                    for (pages[0..count], output[0..count], 0..) |*page, *write, offset| {
                        const at = begin + offset;
                        const next = if (node.branch) 0 else if (at + 1 < child_count) @intFromEnum(output_ids[at + 1]) else node.next;
                        page.* = node.encode(boundaries[at], boundaries[at + 1], next);
                        write.* = .{ .id = output_ids[at], .source = page };
                        children[at] = node.cells[boundaries[at + 1] - 1];
                        children[at].flags = 2;
                        children[at].length = 0;
                        children[at].value = &.{};
                        children[at].reference = @intFromEnum(output_ids[at]);
                        children[at].prefix = 0;
                    }
                    try nodes.write(output[0..count]);
                    begin += count;
                }
            }
            if (depth == 0) {
                if (child_count == 0) try self.setRoot(null);
                if (child_count <= 1) return used;
                if (height == maximum_depth) return error.NoSpace;
                height += 1;
                node = .{ .cells = cells, .branch = true };
                for (children[0..child_count], 0..) |child, at| node.insert(at, child);
                var allocated: [1]storage.PageId = undefined;
                try self.space.allocatePages(&allocated);
                ids[0] = allocated[0];
                try self.setRoot(allocated[0]);
                continue;
            }
            depth -= 1;
            node = try Node.decode(&path[depth], cells);
            const at = positions[depth];
            if (replaced == 1 and child_count == 1 and node.cells[at].reference == children[0].reference and
                std.mem.eql(u8, node.cells[at].keySlice(), children[0].keySlice())) return used;
            for (0..replaced) |_| node.remove(at);
            for (children[0..child_count], 0..) |child, offset| node.insert(at + offset, child);
        }
    }

    pub fn scan(self: Table, cursor: *ScanCursor, output: []ScanEntry) storage.Error!ScanResult {
        if (output.len == 0 or cursor.after_len > cursor.after.len or cursor.after_len > maximum_key) return error.InvalidArgument;
        const saved_length = cursor.after_len;
        var saved: [maximum_key]u8 = undefined;
        @memcpy(saved[0..saved_length], cursor.after[0..saved_length]);
        errdefer {
            @memcpy(cursor.after[0..saved_length], saved[0..saved_length]);
            cursor.after_len = saved_length;
        }
        var id = try self.getRoot() orelse return .{ .count = 0, .more = false };
        var count: usize = 0;
        var depth: usize = 0;
        var page: storage.Page = undefined;
        var cells: [maximum_cells]Cell = undefined;
        var values: ValueReads = .{ .data = .{ .space = self.space } };
        var node: Node = undefined;
        while (true) {
            if (depth == maximum_depth) return error.Corrupt;
            try self.space.readPages(&.{.{ .id = id, .destination = &page }});
            node = try Node.decode(&page, &cells);
            if (!node.branch) break;
            depth += 1;
            const at = @min(node.lowerBound(cursor.after[0..cursor.after_len]), node.count - 1);
            id = @enumFromInt(node.cells[at].reference);
        }
        var at = node.lowerBound(cursor.after[0..cursor.after_len]);
        if (node.count == 0) return error.Corrupt;
        if (at < node.count and std.mem.eql(u8, node.cells[at].keySlice(), cursor.after[0..cursor.after_len])) at += 1;
        while (true) {
            while (at < node.count and count < output.len) : (at += 1) {
                const cell = &node.cells[at];
                const row = &output[count];
                if (row.key.len < cell.key_len or cursor.after.len < cell.key_len) return error.BufferTooSmall;
                @memcpy(row.key[0..cell.key_len], cell.keySlice());
                row.key_len = cell.key_len;
                row.value_len = try values.append(cell, row.value);
                @memcpy(cursor.after[0..cell.key_len], cell.keySlice());
                cursor.after_len = cell.key_len;
                count += 1;
            }
            if (count == output.len or node.next == 0) {
                try values.flush();
                return .{ .count = count, .more = at < node.count or node.next != 0 };
            }
            const last = node.cells[node.count - 1];
            id = @enumFromInt(node.next);
            try self.space.readPages(&.{.{ .id = id, .destination = &page }});
            node = try Node.decode(&page, &cells);
            if (node.branch or node.count == 0 or std.mem.order(u8, last.keySlice(), node.cells[0].keySlice()) != .lt) return error.Corrupt;
            at = 0;
        }
    }
};
