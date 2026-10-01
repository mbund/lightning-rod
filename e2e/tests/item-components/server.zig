const std = @import("std");
const vanilla = @import("vanilla");
const protocols = @import("protocols");
const sessions = @import("sessions");
const encoding = protocols.support;
const nbt = protocols.nbt;
const Payload = vanilla.item_lore.Payload;
const ReadContext = vanilla.item_components.ReadContext;
const WriteContext = vanilla.item_components.WriteContext;

pub const Economy = struct {
    pub const id = "example:economy";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        items: *vanilla.Items,
        menus: *vanilla.PlayerInventory,
        players: *vanilla.Players,
        chat: *vanilla.Chat,
        commands: *vanilla.CommandDispatch,
        reload_request: *vanilla.Reload,
    };

    deps: Dependencies,
    price: u32 = 100,
    originals: [2]?[32]u8 = @splat(null),

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Economy {
        const self = try allocator.create(Economy);
        self.* = .{ .deps = deps };
        try deps.commands.observeCommand(self, onCommand);
        return self;
    }

    fn onCommand(self: *Economy, handle: sessions.Handle, command: []const u8) !void {
        if (std.mem.eql(u8, command, "price_next")) {
            for (self.deps.players.records, &self.originals) |player, *original| {
                if (player.handle == null) continue;
                const slot = try self.deps.items.deps.inventories.get(.{ .owner = player.uuid, .index = 36 });
                original.* = (slot.stack orelse return error.MissingOriginalItem).item;
            }
            self.price = 200;
            self.deps.items.components.changed();
        } else if (std.mem.eql(u8, command, "price_check")) {
            const player = self.deps.players.records[handle.index];
            const store = self.deps.items.deps.inventories;
            const slot = try store.get(.{ .owner = player.uuid, .index = 37 });
            const stack = slot.stack orelse return error.MissingRoundTripItem;
            if (self.originals[handle.index]) |original| {
                if (!std.mem.eql(u8, &original, &stack.item)) return error.RoundTripChangedIdentity;
            }
            const lease = try store.acquireItem(stack.item);
            defer lease.release();
            const view = try vanilla.item_data.View.parse(lease.read().?);
            const lore = view.value(.lore) orelse return error.MissingOriginalLore;
            const count, const rest = try encoding.read_varint(lore);
            if (count != 1) return error.PresentationPersisted;
            var nodes: [16]nbt.Node = undefined;
            var frames: [8]nbt.Frame = undefined;
            const original = try nbt.scan_anonymous(rest, &nodes, &frames);
            const text = if (original.root_node().tag == .string) original.root_node() else original.childNamed("text") orelse return error.InvalidOriginalLore;
            if (!std.mem.eql(u8, try text.string(), "Original lore")) return error.OriginalLoreChanged;
            if ((try store.get(.{ .owner = player.uuid, .index = 38 })).stack != null) return error.UnsupportedComponentAccepted;
            self.deps.menus.changed(handle.index);
            self.deps.chat.system(handle, "Price round trip verified");
        } else if (std.mem.eql(u8, command, "price_reload")) {
            try self.deps.reload_request.stage("item-components");
        }
    }
};

/// Replaces ordinary lore in this composition. No changes to item consumers.
pub const PriceLore = struct {
    pub const id = vanilla.Lore.id;
    pub const Configuration = struct {};
    pub const Dependencies = struct { items: *vanilla.Items, economy: *Economy };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*PriceLore {
        const self = try allocator.create(PriceLore);
        self.* = .{ .deps = deps };
        try deps.items.components.on(.lore, self, .{
            .read = read,
            .write = write,
            .present = present,
            .personalized = true,
            .maximum_extra_bytes = 256,
        });
        return self;
    }

    fn present(_: *PriceLore, _: vanilla.Items.View, _: u128) bool {
        return true;
    }

    fn write(packet: Payload.Writer, self: *PriceLore, context: WriteContext) !Payload.Writer.Done {
        var text_buffer: [80]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buffer, "Price: {d} credits. Customer: {x}", .{ self.deps.economy.price, context.recipient });
        var marker_buffer: [80]u8 = undefined;
        const marker = try sign(&marker_buffer, text, context.value != null);
        var buffer: [256]u8 = undefined;
        var frames: [2]nbt.WriteFrame = undefined;
        var writer = nbt.Writer.init(&buffer, &frames);
        try writer.beginAnonymousCompound();
        try writer.putString("text", text);
        try writer.putString("insertion", marker);
        try writer.endCompound();
        return vanilla.item_lore.writeAppending(packet, context.value, &.{try writer.finish()});
    }

    fn read(packet: Payload.Reader, _: *PriceLore, context: ReadContext) !Payload.Reader.Done {
        var lines = try packet.value();
        if (lines.remaining > 256) return error.InvalidLore;
        var values: [256][]const u8 = undefined;
        var count: usize = 0;
        while (try lines.next()) |entry| {
            const value, const done = try entry.value();
            values[count] = value;
            count += 1;
            try lines.advance(done);
        }
        if (count != 0) {
            var nodes: [32]nbt.Node = undefined;
            var frames: [8]nbt.Frame = undefined;
            const footer = try nbt.scan_anonymous(values[count - 1], &nodes, &frames);
            if (footer.root_node().tag == .compound) {
                if (footer.childNamed("insertion")) |insertion| {
                    const marker = try insertion.string();
                    if (std.mem.startsWith(u8, marker, "lr-price:")) {
                        const text = footer.childNamed("text") orelse return error.InvalidPriceFooter;
                        const retained = marker.len > 9 and marker[9] == '1';
                        var expected: [80]u8 = undefined;
                        if (!std.mem.eql(u8, marker, try sign(&expected, try text.string(), retained))) return error.InvalidPriceFooter;
                        count -= 1;
                        context.retain.* = retained or count != 0;
                    }
                }
            }
        }
        context.output.* = try encoding.write_varint(context.output.*, @intCast(count));
        for (values[0..count]) |value| context.output.* = try encoding.write_bytes(context.output.*, value);
        return lines.finish();
    }
};

// A fixed secret keeps this fixture reproducible across execve. A real plugin
// would store its own secret. Only its authenticated footer is removed on input.
fn sign(buffer: []u8, text: []const u8, retained: bool) ![]const u8 {
    var digest: [32]u8 = undefined;
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init("item-components fixture key");
    hmac.update(&.{@intFromBool(retained)});
    hmac.update(text);
    hmac.final(&digest);
    return std.fmt.bufPrint(buffer, "lr-price:{d}:{s}", .{ @intFromBool(retained), std.fmt.bytesToHex(digest, .lower) });
}
