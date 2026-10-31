const std = @import("std");
const protocols = @import("protocols");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const support = @import("protocol_support");
const data = @import("item_data.zig");

const schemas = block: {
    var values: [protocols.implementations.len]type = undefined;
    for (protocols.implementations, &values) |Version, *value| value.* = struct {
        pub const protocol_number = Version.protocol_number;
        pub const SlotComponent = Version.Protocol.SlotComponent;
        pub const case_tags = Version.Protocol.case_tags;
    };
    break :block values;
};

pub const Presentation = enum {
    absent,
    /// The stored addition or removal is presented unchanged.
    stored,
    added,
    removed,
};

pub const RetentionContext = struct {
    kind: u32,
    recipient: u128,
    component: data.Component,
};

pub const ReadContext = struct {
    /// Write the plugin's canonical payload here. It becomes immutable item data.
    output: *[]u8,
    /// False removes a verified presentation-only component from the proposal.
    retain: *bool,
    selected: *const sessions.Protocol,
    recipient: u128,
};

pub const WriteContext = struct {
    /// Borrowed for this call. Rendering must not mutate the stored definition.
    item: data.View,
    value: ?[]const u8,
    registry: packets.Registry,
    protocol: i32,
    /// Reading this requires registration with .personalized = true to disable
    /// shared fanout between different recipients.
    recipient: u128,
};

pub const Dispatch = support.cursor.Dispatch(schemas, "SlotComponent", "data", ReadContext, WriteContext);

pub const Components = struct {
    pub const Provider = struct {
        context: *anyopaque,
        vtable: *const VTable,
        const VTable = struct {
            present: ?*const fn (*anyopaque, data.View, u128, ?data.Component) Presentation,
            retain: ?*const fn (*anyopaque, RetentionContext) anyerror!bool,
        };
    };

    dispatch: Dispatch,
    providers: []Provider,
    order: []usize,
    personalized: bool = false,
    has_presentation: bool = false,
    has_retention: bool = false,
    revision: u64 = 0,
    extra_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Components {
        const dispatch = try Dispatch.init(allocator, capacity);
        errdefer allocator.free(dispatch.entries);
        const providers = try allocator.alloc(Provider, capacity);
        errdefer allocator.free(providers);
        return .{ .dispatch = dispatch, .providers = providers, .order = try allocator.alloc(usize, capacity) };
    }

    /// One owner per component. The owner defines its stored payload format and
    /// supplies concrete cursor codecs checked against every selected protocol.
    pub fn on(self: *Components, comptime tag: Dispatch.Tag, owner: anytype, comptime callbacks: anytype) !void {
        const index = self.dispatch.count;
        const extra = if (@hasField(@TypeOf(callbacks), "maximum_extra_bytes")) callbacks.maximum_extra_bytes else 0;
        const total = try std.math.add(usize, self.extra_bytes, extra);
        if (@hasField(@TypeOf(callbacks), "present") and !@hasField(@TypeOf(callbacks), "maximum_extra_bytes"))
            @compileError("computed components must declare their maximum additional encoded bytes");
        try self.dispatch.on(tag, owner, callbacks);
        var position = index;
        while (position != 0 and self.dispatch.entries[self.order[position - 1]].key > self.dispatch.entries[index].key) : (position -= 1) self.order[position] = self.order[position - 1];
        self.order[position] = index;
        self.extra_bytes = total;
        self.has_presentation = self.has_presentation or @hasField(@TypeOf(callbacks), "present");
        self.has_retention = self.has_retention or @hasField(@TypeOf(callbacks), "retain");
        const Adapter = struct {
            const vtable: Provider.VTable = .{
                .present = if (@hasField(@TypeOf(callbacks), "present")) invoke else null,
                .retain = if (@hasField(@TypeOf(callbacks), "retain")) retainComponent else null,
            };

            fn retainComponent(raw: *anyopaque, context: RetentionContext) !bool {
                const typed: @TypeOf(owner) = @ptrCast(@alignCast(raw));
                return callbacks.retain(typed, context);
            }

            fn invoke(raw: *anyopaque, view: data.View, recipient: u128, stored: ?data.Component) Presentation {
                const typed: @TypeOf(owner) = @ptrCast(@alignCast(raw));
                return callbacks.present(typed, view, recipient, stored);
            }
        };
        self.providers[index] = .{ .context = owner, .vtable = &Adapter.vtable };
        if (@hasField(@TypeOf(callbacks), "personalized")) self.personalized = self.personalized or callbacks.personalized;
    }

    /// Coalesces presentation changes into the next inventory and equipment pass.
    pub fn changed(self: *Components) void {
        self.revision += 1;
    }

    /// Offsets borrow the pinned definition. Bindings stay stable after registration is sealed.
    pub fn resolve(self: *const Components, view: data.View, offsets: []usize) !void {
        std.debug.assert(offsets.len == self.dispatch.count);
        var it = view.iterator();
        var offset = view.bytes.len - it.rest.len;
        var next = it.next();
        for (self.order[0..self.dispatch.count]) |index| {
            const key = self.dispatch.entries[index].key;
            if (next) |component| {
                if (component.key < key) return error.UnsupportedComponent;
                if (component.key == key) {
                    offsets[index] = offset;
                    offset = view.bytes.len - it.rest.len;
                    next = it.next();
                    continue;
                }
            }
            offsets[index] = std.math.maxInt(usize);
        }
        if (next != null) return error.UnsupportedComponent;
    }

    pub fn retain(self: *const Components, context: RetentionContext) !bool {
        if (!self.has_retention) return true;
        var low: usize = 0;
        var high = self.dispatch.count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const index = self.order[middle];
            if (self.dispatch.entries[index].key < context.component.key) low = middle + 1 else high = middle;
        }
        if (low == self.dispatch.count) return error.UnsupportedComponent;
        const index = self.order[low];
        if (self.dispatch.entries[index].key != context.component.key) return error.UnsupportedComponent;
        const provider = self.providers[index];
        if (provider.vtable.retain) |call| return call(provider.context, context);
        return true;
    }

    pub fn requiresCorrection(self: *const Components, view: data.View, recipient: u128) !bool {
        if (!self.has_presentation) return false;
        var offsets: [data.maximum_components]usize = undefined;
        const count = self.dispatch.count;
        std.debug.assert(count <= offsets.len);
        try self.resolve(view, offsets[0..count]);
        for (offsets[0..count], 0..) |offset, index| {
            if (self.providers[index].vtable.present == null) continue;
            const stored = if (offset == std.math.maxInt(usize)) null else view.at(offset);
            switch (self.present(index, view, recipient, stored)) {
                .added, .removed => return true,
                .absent => if (stored != null) return true,
                .stored => {},
            }
        }
        return false;
    }

    pub fn present(self: *const Components, index: usize, view: data.View, recipient: u128, stored: ?data.Component) Presentation {
        std.debug.assert(index < self.dispatch.count);
        if (stored) |component| std.debug.assert(component.key == self.dispatch.entries[index].key);
        const provider = self.providers[index];
        const result = if (provider.vtable.present) |call| call(provider.context, view, recipient, stored) else if (stored != null) Presentation.stored else Presentation.absent;
        std.debug.assert(result != .stored or stored != null);
        return result;
    }
};
