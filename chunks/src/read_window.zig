const std = @import("std");
const chunks = @import("chunks.zig");

pub fn ReadWindow(comptime capacity: usize) type {
    std.debug.assert(capacity > 0 and capacity <= 192);
    return struct {
        const Self = @This();
        client: chunks.Chunks.Client,
        sections: [capacity]chunks.Section = undefined,
        leases: [capacity]chunks.Lease = undefined,
        count: usize = 0,

        /// The window holds at most the client's budget.
        pub fn init(client: chunks.Chunks.Client) Self {
            return .{ .client = client };
        }

        /// Views borrow the window until the next readMany or deinit. Terrain must remain unmodified.
        /// Keep optional sections for reuse. Cache admission releases them before waiting for space.
        pub fn readMany(self: *Self, sections: []const chunks.Section, views: []chunks.View) !void {
            std.debug.assert(self.count <= capacity and sections.len == views.len);
            if (sections.len > capacity) return error.WorkingSetTooLarge;
            if (sections.len == 0) {
                self.deinit();
                return;
            }
            // Everything held already, as for reads near the last: the views, and nothing moves.
            if (self.viewsHeld(sections, views)) return;
            var required: usize = 0;
            for (0..self.count) |at| {
                const wanted = for (sections) |request| {
                    if (std.meta.eql(self.sections[at], request)) break true;
                } else false;
                if (!wanted) continue;
                std.mem.swap(chunks.Section, &self.sections[required], &self.sections[at]);
                std.mem.swap(chunks.Lease, &self.leases[required], &self.leases[at]);
                required += 1;
            }
            var missing: [capacity]chunks.Section = undefined;
            var count: usize = 0;
            for (sections) |section| {
                const present = for (self.sections[0..required]) |held| {
                    if (std.meta.eql(section, held)) break true;
                } else false;
                if (present) continue;
                const duplicate = for (missing[0..count]) |planned| {
                    if (std.meta.eql(section, planned)) break true;
                } else false;
                if (duplicate) continue;
                missing[count] = section;
                count += 1;
            }
            const limit = @min(capacity, self.client.budget());
            if (required + count > limit) return error.WorkingSetTooLarge;
            var retention: chunks.Chunks.Retention = .{ .leases = self.leases[required..self.count], .limit = limit - required - count };
            var acquired: usize = 0;
            defer self.count = required + retention.leases.len + acquired;
            if (count != 0) {
                var fresh: [capacity]chunks.Lease = undefined;
                try self.client.acquireManyRetaining(missing[0..count], fresh[0..count], &retention);
                const start = required + retention.leases.len;
                @memcpy(self.sections[start..][0..count], missing[0..count]);
                @memcpy(self.leases[start..][0..count], fresh[0..count]);
                acquired = count;
            }
            const total = required + retention.leases.len + acquired;
            std.debug.assert(total <= limit);
            for (sections, views) |section, *view| {
                const at = for (self.sections[0..total], 0..) |held, index| {
                    if (std.meta.eql(section, held)) break index;
                } else unreachable;
                view.* = self.leases[at].view();
            }
        }

        /// Fills the views if the window holds every section, the last held first.
        fn viewsHeld(self: *const Self, sections: []const chunks.Section, views: []chunks.View) bool {
            for (sections, views) |section, *view| {
                const at = for (0..self.count) |offset| {
                    const index = self.count - 1 - offset;
                    if (std.meta.eql(self.sections[index], section)) break index;
                } else return false;
                view.* = self.leases[at].view();
            }
            return true;
        }

        pub fn deinit(self: *Self) void {
            self.client.chunks.releaseMany(self.leases[0..self.count]);
            self.count = 0;
        }
    };
}
