const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");

pub fn main(init: std.process.Init) !void {
    var permissions: Permissions = .{};
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(vanilla.commands.Commands, .{
                .permission_policy = vanilla.commands.Policy.init(&permissions, Permissions.allows),
            }),
        }),
        lightning_rod.plugin.configured(Probe, .{ .permissions = &permissions }),
    });
    try e2e.profile.run(init, plugins, .{});
}

const Permissions = struct {
    players: ?*vanilla.Players = null,
    enabled: bool = true,

    pub fn allows(self: *Permissions, uuid: u128, permission: *const vanilla.commands.Permission) bool {
        if (std.mem.eql(u8, permission.name, "server.reload")) return false;
        if (!self.enabled) return false;

        const players = self.players orelse return false;

        for (players.records) |player| if (player.uuid == uuid and player.handle != null) {
            const recipient = "alice";
            return std.mem.eql(u8, player.name[0..player.name_len], recipient);
        };

        return false;
    }
};

const Probe = struct {
    pub const id = "e2e:commands";

    pub const Configuration = struct {
        permissions: *Permissions,
        disabled_command: bool = false,
    };

    pub const Dependencies = struct {
        commands: *vanilla.commands.Commands,
        players: *vanilla.Players,
    };
    const Empty = struct {};

    const Choose = struct {
        target: []const u8,
        amount: u32,
    };

    const Mode = struct { mode: enum { creative, survival } };

    const Echo = struct { message: []const u8 };

    const secret_permission: vanilla.commands.Permission = .{ .name = "probe.secret", .description = "Restricted test command" };
    permissions: *Permissions,
    commands: *vanilla.commands.Commands,
    const maximum_amount = 7;

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .permissions = config.permissions, .commands = deps.commands };
        config.permissions.players = deps.players;

        const root = try deps.commands.literal(.{ .name = "probe", .description = "Command acceptance checks" });

        if (config.disabled_command)
            _ = try root.add(self, vanilla.commands.leaf(Probe, Empty, .{
                .name = "disabled",
                .description = "Opt-in command",
                .handler = entry,
                .arguments = .{},
            }));
        _ = try root.add(self, vanilla.commands.leaf(Probe, Choose, .{
            .name = "choose",
            .description = "Choose a suggested target",
            .handler = choose,
            .arguments = .{ .target = .{ .suggest = suggest }, .amount = .{ .minimum = 1, .maximum = maximum_amount } },
        }));
        _ = try root.add(self, vanilla.commands.leaf(Probe, Mode, .{
            .name = "mode",
            .description = "Choose a typed enum",
            .handler = mode,
            .arguments = .{ .mode = .{} },
        }));
        _ = try root.add(self, vanilla.commands.leaf(Probe, Echo, .{
            .name = "echo",
            .description = "Echo a message",
            .handler = echo,
            .arguments = .{ .message = .{ .greedy = true } },
        }));
        const admin = try root.literal(.{ .name = "admin", .permission = &secret_permission });
        _ = try admin.add(self, vanilla.commands.leaf(Probe, Empty, .{
            .name = "secret",
            .description = "SECRET_PERMISSION",
            .handler = secret,
            .arguments = .{},
        }));
        _ = try admin.add(self, vanilla.commands.leaf(Probe, Empty, .{
            .name = "revoke",
            .description = "Revoke access immediately",
            .handler = revoke,
            .arguments = .{},
        }));

        inline for (.{ "one", "two", "three", "four", "five", "six", "seven" }) |name|
            _ = try root.add(self, vanilla.commands.leaf(Probe, Empty, .{
                .name = name,
                .description = "Pagination entry",
                .handler = entry,
                .arguments = .{},
            }));

        return self;
    }

    fn choose(_: *Probe, context: vanilla.commands.Context, args: Choose) !void {
        std.debug.assert(args.amount <= maximum_amount);
        var buffer: [160]u8 = undefined;
        context.reply(try std.fmt.bufPrint(&buffer, "choice {s}={d}", .{ args.target, args.amount }));
    }

    fn mode(_: *Probe, context: vanilla.commands.Context, args: Mode) !void {
        context.reply(@tagName(args.mode));
    }

    fn echo(_: *Probe, context: vanilla.commands.Context, args: Echo) !void {
        context.reply(args.message);
    }

    fn secret(_: *Probe, context: vanilla.commands.Context, _: Empty) !void {
        context.reply("secret granted");
    }

    fn revoke(self: *Probe, context: vanilla.commands.Context, _: Empty) !void {
        self.permissions.enabled = false;
        self.commands.permissionsChanged();
        context.reply("access revoked");
    }

    fn entry(_: *Probe, context: vanilla.commands.Context, _: Empty) !void {
        context.reply("entry executed");
    }

    fn suggest(_: *Probe, context: vanilla.commands.CompletionContext, output: *vanilla.commands.Suggestions) void {
        std.debug.assert(std.mem.eql(u8, context.argument, "target"));

        for ([_][]const u8{ "alpha", "amber", "beta" }) |name| {
            if (!std.mem.startsWith(u8, name, context.prefix)) continue;

            var tooltip: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&tooltip, "Custom target: {s}", .{name}) catch unreachable;
            output.add(.{ .text = name, .tooltip = text }) catch return;
        }
    }
};
