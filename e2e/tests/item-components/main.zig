const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const protocols = @import("protocols");
const vanilla = @import("vanilla");
const sessions = @import("sessions");

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(lightning_rod.plugin.remove(e2e.profile.plugins(), vanilla.Lore), .{
            lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 2, .render_distance = 2 }),
        }),
        lightning_rod.plugin.configured(Economy, .{}),
        lightning_rod.plugin.configured(PriceLore, .{}),
    });
    try e2e.profile.run(init, plugins, .{ .plaintext = true, .reload_executable = "/proc/self/exe" });
}

const Payload = vanilla.item_lore.Payload;
const ReadContext = vanilla.item_components.ReadContext;
const WriteContext = vanilla.item_components.WriteContext;

const Economy = struct {
    pub const id = "example:economy";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        items: *vanilla.Items,
        inventories: *vanilla.Inventories,
        menus: *vanilla.PlayerInventory,
        players: *vanilla.Players,
        control: *e2e.Control,
        reload: *vanilla.Reload,
    };

    deps: Dependencies,
    price: u32 = 100,
    originals: [2]?[32]u8 = @splat(null),

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Economy {
        const self = try allocator.create(Economy);
        self.* = .{ .deps = deps };
        try deps.items.deps.definitions.addDefinitions(.{ .items = &.{
            .{ .name = "minecraft:paper", .stack_size = 8 },
            .{ .name = "minecraft:iron_pickaxe", .durability = 40 },
            .{ .name = "minecraft:diamond_pickaxe", .durability = 0 },
        } });
        deps.control.on(self, onMessage);
        return self;
    }

    fn onMessage(self: *Economy, handle: sessions.Handle, message: []const u8) !e2e.Control.Result {
        if (std.mem.eql(u8, message, "price_next")) {
            for (self.deps.players.records, &self.originals) |player, *original| {
                if (player.handle == null) continue;
                const slot = try self.deps.inventories.get(.{ .owner = player.uuid, .index = 36 });
                original.* = (slot.stack orelse return error.MissingOriginalItem).item;
            }
            self.price = 200;
            self.deps.items.components.changed();
        } else if (std.mem.eql(u8, message, "price_check")) {
            const player = self.deps.players.records[handle.index];
            const store = self.deps.inventories;
            const slot = try store.get(.{ .owner = player.uuid, .index = 37 });
            const stack = slot.stack orelse return error.MissingRoundTripItem;
            if (self.originals[handle.index]) |original| {
                if (!std.mem.eql(u8, &original, &stack.item)) return error.RoundTripChangedIdentity;
            }
            const lease = try store.acquireItem(stack.item);
            defer lease.release();
            const view = try vanilla.item_data.View.parse(lease.read().?);
            const lore = view.value(.lore) orelse return error.MissingOriginalLore;
            const count, const rest = try protocols.support.read_varint(lore);
            if (count != 1) return error.PresentationPersisted;
            var nodes: [16]protocols.nbt.Node = undefined;
            var frames: [8]protocols.nbt.Frame = undefined;
            const original = try protocols.nbt.scan_anonymous(rest, &nodes, &frames);
            const text = if (original.root_node().tag == .string) original.root_node() else original.childNamed("text") orelse return error.InvalidOriginalLore;
            if (!std.mem.eql(u8, try text.string(), "Original lore")) return error.OriginalLoreChanged;
            if ((try store.get(.{ .owner = player.uuid, .index = 38 })).stack != null) return error.UnsupportedComponentAccepted;
            self.deps.menus.changed(handle.index);
            try self.deps.control.send(handle, "Price round trip verified");
        } else if (std.mem.eql(u8, message, "price_reload")) {
            try self.deps.reload.stage("item-components");
        } else return .unhandled;
        return .handled;
    }
};

const PriceLore = struct {
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

    fn present(_: *PriceLore, _: vanilla.Items.View, _: u128, _: ?vanilla.Items.Component) vanilla.item_components.Presentation {
        return .added;
    }

    fn write(packet: Payload.Writer, self: *PriceLore, context: WriteContext) !Payload.Writer.Done {
        var text_buffer: [80]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buffer, "Price: {d} credits. Customer: {x}", .{ self.deps.economy.price, context.recipient });
        var marker_buffer: [80]u8 = undefined;
        const marker = try sign(&marker_buffer, text, context.value != null);
        var buffer: [256]u8 = undefined;
        var frames: [2]protocols.nbt.WriteFrame = undefined;
        var writer = protocols.nbt.Writer.init(&buffer, &frames);
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
            var nodes: [32]protocols.nbt.Node = undefined;
            var frames: [8]protocols.nbt.Frame = undefined;
            const footer = try protocols.nbt.scan_anonymous(values[count - 1], &nodes, &frames);
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
        context.output.* = try protocols.support.write_varint(context.output.*, @intCast(count));
        for (values[0..count]) |value| context.output.* = try protocols.support.write_bytes(context.output.*, value);
        return lines.finish();
    }
};

// A fixed secret keeps signatures reproducible across execve.
fn sign(buffer: []u8, text: []const u8, retained: bool) ![]const u8 {
    var digest: [32]u8 = undefined;
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init("item-components fixture key");
    hmac.update(&.{@intFromBool(retained)});
    hmac.update(text);
    hmac.final(&digest);
    return std.fmt.bufPrint(buffer, "lr-price:{d}:{s}", .{ @intFromBool(retained), std.fmt.bytesToHex(digest, .lower) });
}
