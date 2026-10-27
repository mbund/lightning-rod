const std = @import("std");
const lightning_rod = @import("lightning_rod");
const catalog = @import("catalog.zig");

pub const Worlds = struct {
    const magic = "LRSKYRT1";

    io: std.Io,
    mutex: std.Io.Mutex = .init,
    space: lightning_rod.storage.Space,
    root: lightning_rod.storage.PageId,
    roots: [catalog.endpoints]u64,

    pub fn init(store: *lightning_rod.storage.Store, io: std.Io) !Worlds {
        const space = try store.openSpace("skyblock:worlds");
        var roots: [catalog.endpoints]u64 = @splat(0);
        var page: lightning_rod.storage.Page = @splat(0);
        const root = if (try space.getRoot()) |id| blk: {
            try space.readPages(&.{.{ .id = id, .destination = &page }});
            if (!std.mem.eql(u8, page[0..magic.len], magic)) return error.CorruptWorldDirectory;
            for (&roots, 0..) |*value, index| {
                value.* = std.mem.readInt(u64, page[8 + index * 8 ..][0..8], .little);
                if (value.* == 0) continue;
                if (value.* == @intFromEnum(id)) return error.CorruptWorldDirectory;
                for (roots[0..index]) |previous| if (previous == value.*) return error.CorruptWorldDirectory;
            }
            for (page[8 + roots.len * 8 ..]) |byte| if (byte != 0) return error.CorruptWorldDirectory;
            break :blk id;
        } else blk: {
            var ids: [1]lightning_rod.storage.PageId = undefined;
            try space.allocatePages(&ids);
            @memcpy(page[0..magic.len], magic);
            try space.writePages(&.{.{ .id = ids[0], .source = &page }});
            try space.setRoot(ids[0]);
            break :blk ids[0];
        };
        return .{ .io = io, .space = space, .root = root, .roots = roots };
    }

    pub fn open(self: *Worlds, index: usize) !?lightning_rod.storage.Scope {
        std.debug.assert(index < self.roots.len);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const root = self.roots[index];
        return if (root == 0) null else try lightning_rod.storage.Scope.open(self.space, @enumFromInt(root));
    }

    pub fn create(self: *Worlds, index: usize) !lightning_rod.storage.Scope {
        std.debug.assert(index < self.roots.len);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.roots[index] == 0);
        const scope = try lightning_rod.storage.Scope.create(self.space);
        var page: lightning_rod.storage.Page = undefined;
        try self.space.readPages(&.{.{ .id = self.root, .destination = &page }});
        std.mem.writeInt(u64, page[8 + index * 8 ..][0..8], @intFromEnum(scope.page), .little);
        try self.space.writePages(&.{.{ .id = self.root, .source = &page }});
        self.roots[index] = @intFromEnum(scope.page);
        return scope;
    }
};
