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
        present: ?*const fn (*anyopaque, data.View, u128) bool,
    };

    dispatch: Dispatch,
    providers: []Provider,
    personalized: bool = false,
    has_presentation: bool = false,
    revision: u64 = 0,
    extra_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Components {
        return .{ .dispatch = try Dispatch.init(allocator, capacity), .providers = try allocator.alloc(Provider, capacity) };
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
        self.extra_bytes = total;
        self.has_presentation = self.has_presentation or @hasField(@TypeOf(callbacks), "present");
        self.providers[index] = .{
            .context = owner,
            .present = if (@hasField(@TypeOf(callbacks), "present")) struct {
                fn present(raw: *anyopaque, view: data.View, recipient: u128) bool {
                    const typed: @TypeOf(owner) = @ptrCast(@alignCast(raw));
                    return callbacks.present(typed, view, recipient);
                }
            }.present else null,
        };
        if (@hasField(@TypeOf(callbacks), "personalized")) self.personalized = self.personalized or callbacks.personalized;
    }

    /// Coalesces presentation changes into the next inventory and equipment pass.
    pub fn changed(self: *Components) void {
        self.revision += 1;
    }

    pub fn present(self: *const Components, index: usize, view: data.View, recipient: u128) bool {
        const provider = self.providers[index];
        if (provider.present) |call| return call(provider.context, view, recipient);
        const entry = view.get(self.dispatch.entries[index].key) orelse return false;
        return entry.value != null;
    }
};
