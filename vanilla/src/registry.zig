const std = @import("std");
const values = @import("content_values.zig");
const assert = std.debug.assert;

pub fn Registry(comptime Owner: type) type {
    return struct {
        const Self = @This();
        const Definitions = Owner.Definitions;
        const Data = Owner.Data;
        pub const Configuration = struct { prepared: ?*const Owner = null, definitions: Definitions = .{} };
        pub const Exclusion = struct {
            field: std.meta.FieldEnum(Definitions),
            name: []const u8,
            registry: []const u8 = "",
        };
        pub const Contribution = struct { definitions: Definitions, exclusions: []const Exclusion = &.{} };
        const Key = struct { name: []const u8, registry: []const u8 };
        const KeyContext = struct {
            pub fn hash(_: @This(), key: Key) u64 {
                var value = std.hash.Wyhash.init(0);
                value.update(key.registry);
                value.update(&.{0});
                value.update(key.name);
                return value.final();
            }
            pub fn eql(_: @This(), a: Key, b: Key) bool {
                return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.registry, b.registry);
            }
        };
        const Version = struct {
            backing: std.mem.Allocator,
            memory: std.heap.ArenaAllocator,
            definitions: Definitions,
            sources: []const Contribution,
            data: Data,
            users: std.atomic.Value(usize) = .init(1),
        };
        const Listener = struct {
            next: ?*Listener = null,
            context: *anyopaque,
            vtable: *const VTable,
            const VTable = struct { invoke: *const fn (*anyopaque) anyerror!void };
        };
        owner: *Owner,
        allocator: std.mem.Allocator,
        version: *Version,
        first: ?*Listener = null,
        last: ?*Listener = null,
        first_check: ?*Listener = null,
        last_check: ?*Listener = null,
        staged: bool = false,
        failed: bool = false,
        publishing: bool = false,

        pub fn init(owner: *Owner, allocator: std.mem.Allocator, configuration: Configuration) !void {
            const self = &owner.registry;
            if (configuration.prepared) |prepared| {
                assert(!prepared.registry.failed and !prepared.registry.staged);
                inline for (@typeInfo(Definitions).@"struct".field_names) |field| if (@field(configuration.definitions, field).len != 0) return error.PreparedRegistryCannotRegister;
                const previous = prepared.registry.version;
                const users = previous.users.fetchAdd(1, .monotonic);
                assert(users > 0 and users < std.math.maxInt(usize));
                self.* = .{ .owner = owner, .allocator = allocator, .version = previous };
                self.install(previous.data);
                return;
            }
            self.* = .{ .owner = owner, .allocator = allocator, .version = undefined };
            self.version = try self.build(null, .{ .definitions = configuration.definitions }, false);
            self.install(self.version.data);
        }

        fn build(self: *Self, replace: ?usize, contribution: Contribution, initialized: bool) !*Version {
            const version = try self.allocator.create(Version);
            version.* = .{ .backing = self.allocator, .memory = .init(self.allocator), .definitions = undefined, .sources = undefined, .data = undefined };
            errdefer {
                version.memory.deinit();
                self.allocator.destroy(version);
            }
            const allocator = version.memory.allocator();
            const previous = if (initialized) self.version.sources else &.{};
            const sources = try allocator.alloc(Contribution, previous.len + @intFromBool(replace == null));
            for (previous, sources[0..previous.len], 0..) |source, *target, index| target.* = try values.clone(allocator, if (replace == index) contribution else source, 0);
            if (replace == null) sources[sources.len - 1] = try values.clone(allocator, contribution, 0);
            version.sources = sources;
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const temporary = scratch.allocator();
            var combined: Definitions = .{};
            const info = @typeInfo(Definitions).@"struct";
            inline for (info.field_names, info.field_types) |field, Field| {
                const T = @typeInfo(Field).pointer.child;
                var count: usize = 0;
                var filtered = false;
                for (sources) |source| {
                    count = try std.math.add(usize, count, @field(source.definitions, field).len);
                    for (source.exclusions) |exclusion| {
                        filtered = filtered or exclusion.field == @field(std.meta.FieldEnum(Definitions), field);
                    }
                }
                if (!filtered) {
                    const entries = try allocator.alloc(T, count);
                    var written: usize = 0;
                    for (sources) |source| {
                        const part = @field(source.definitions, field);
                        @memcpy(entries[written..][0..part.len], part);
                        written += part.len;
                    }
                    assert(written == entries.len);
                    @field(combined, field) = entries;
                } else {
                    var entries: std.ArrayList(T) = .empty;
                    var excluded: std.HashMapUnmanaged(Key, void, KeyContext, 80) = .empty;
                    var index = sources.len;
                    while (index > 0) {
                        index -= 1;
                        const source = sources[index];
                        const part = @field(source.definitions, field);
                        var at = part.len;
                        while (at > 0) {
                            at -= 1;
                            if (comptime @typeInfo(T) == .@"struct" and @hasField(T, "name")) {
                                const key: Key = .{ .name = part[at].name, .registry = if (@hasField(T, "registry")) part[at].registry else "" };
                                if (excluded.contains(key)) continue;
                            }
                            try entries.append(temporary, part[at]);
                        }
                        for (source.exclusions) |exclusion| {
                            if (exclusion.field != @field(std.meta.FieldEnum(Definitions), field)) continue;
                            assert(comptime @typeInfo(T) == .@"struct" and @hasField(T, "name"));
                            try excluded.put(temporary, .{ .name = exclusion.name, .registry = exclusion.registry }, {});
                        }
                    }
                    std.mem.reverse(T, entries.items);
                    @field(combined, field) = try allocator.dupe(T, entries.items);
                }
            }
            version.definitions = combined;
            version.data = try self.owner.compile(allocator, scratch.allocator(), combined);
            return version;
        }

        fn install(self: *Self, data: Data) void {
            inline for (@typeInfo(Data).@"struct".field_names) |field| @field(self.owner, field) = @field(data, field);
        }

        pub const Source = struct {
            registry: *Self,
            index: usize,
            pub fn replace(self: Source, definitions: Definitions) !void {
                var change = try self.registry.stage(self, definitions);
                try change.commit();
            }
        };
        pub const Change = struct {
            registry: *Self,
            previous: *Version,
            source: Source,
            finished: bool = false,

            pub fn cancel(self: *Change) void {
                if (self.finished) return;
                const registry = self.registry;
                assert(registry.staged and !registry.publishing);
                const next = registry.version;
                registry.version = self.previous;
                registry.install(self.previous.data);
                registry.staged = false;
                next.memory.deinit();
                registry.allocator.destroy(next);
                self.finished = true;
            }

            pub fn commit(self: *Change) !void {
                assert(!self.finished);
                const registry = self.registry;
                assert(registry.staged and !registry.failed and !registry.publishing);
                registry.staged = false;
                registry.publishing = true;
                defer registry.publishing = false;
                self.finished = true;
                errdefer registry.failed = true;
                var listener = registry.first;
                while (listener) |entry| : (listener = entry.next) try entry.vtable.invoke(entry.context);
                release(self.previous);
            }
        };

        pub fn stage(self: *Self, source: ?Source, definitions: Definitions) !Change {
            return self.stageExcluded(source, definitions, &.{});
        }

        pub fn stageExcluded(self: *Self, source: ?Source, definitions: Definitions, exclusions: []const Exclusion) !Change {
            assert(!self.staged and !self.publishing and !self.failed);
            if (source) |handle| assert(handle.registry == self and handle.index < self.version.sources.len);
            const index = if (source) |handle| handle.index else self.version.sources.len;
            const next = try self.build(if (source) |_| index else null, .{ .definitions = definitions, .exclusions = exclusions }, true);
            const previous = self.version;
            self.version = next;
            self.install(next.data);
            self.staged = true;
            return .{ .registry = self, .previous = previous, .source = .{ .registry = self, .index = index } };
        }

        /// Initialization only. Definitions are owned and handler owners are borrowed.
        pub fn add(self: *Self, definitions: Definitions) !void {
            _ = try self.register(definitions);
        }
        pub fn register(self: *Self, definitions: Definitions) !Source {
            var change = try self.stage(null, definitions);
            try change.commit();
            return change.source;
        }
        pub fn refresh(self: *Self) !void {
            if (self.staged) return;
            const first = self.version.sources[0];
            var change = try self.stageExcluded(.{ .registry = self, .index = 0 }, first.definitions, first.exclusions);
            try change.commit();
        }
        pub fn contributions(self: *const Self) []const Contribution {
            return self.version.sources;
        }

        pub fn onChange(self: *Self, owner: anytype, comptime callback: anytype) !void {
            try self.listen(owner, callback, false);
        }
        pub fn checkWith(self: *Self, owner: anytype, comptime callback: anytype) !void {
            try self.listen(owner, callback, true);
        }
        fn listen(self: *Self, owner: anytype, comptime callback: anytype, check: bool) !void {
            assert(!self.failed and !self.publishing);
            const Adapter = struct {
                const vtable: Listener.VTable = .{ .invoke = invoke };
                fn invoke(raw: *anyopaque) !void {
                    const typed: @TypeOf(owner) = @ptrCast(@alignCast(raw));
                    try callback(typed);
                }
            };
            const entry = try self.allocator.create(Listener);
            entry.* = .{ .context = owner, .vtable = &Adapter.vtable };
            const first = if (check) &self.first_check else &self.first;
            const last = if (check) &self.last_check else &self.last;
            if (last.*) |previous| previous.next = entry else first.* = entry;
            last.* = entry;
        }
        pub fn validate(self: *const Self) !void {
            assert(!self.failed and !self.staged and !self.publishing);
            var entry = self.first_check;
            while (entry) |check| : (entry = check.next) try check.vtable.invoke(check.context);
        }
        pub fn close(self: *Self) void {
            const users = self.version.users.fetchSub(1, .acq_rel);
            assert(users > 0);
        }
        fn release(version: *Version) void {
            const users = version.users.fetchSub(1, .acq_rel);
            assert(users > 0);
            if (users == 1) {
                version.memory.deinit();
                version.backing.destroy(version);
            }
        }
    };
}
