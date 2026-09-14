const std = @import("std");
const fixture = @import("../../src/fixture.zig");
const vanilla = @import("vanilla");

const commands = vanilla.commands;

pub const State = struct {
    pub const id = "e2e:external_value_not_a_plugin";
    players: ?*vanilla.Players = null,
    enabled: bool = true,
    reload: bool = false,

    pub fn allows(context: *anyopaque, uuid: u128, permission: *const commands.Permission) bool {
        const self: *State = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, permission.name, "server.reload") and !self.reload) return false;
        if (!self.enabled) return false;

        const players = self.players orelse return false;

        for (players.records) |player| if (player.uuid == uuid and player.handle != null) {
            const recipient = if (self.reload and std.mem.eql(u8, permission.name, "server.reload.notify")) "bob" else "alice";
            return std.mem.eql(u8, player.name[0..player.name_len], recipient);
        };

        return false;
    }
};

pub const settings: fixture.Settings = .{ .commands = .{ .enabled = true } };

pub const Probe = struct {
    pub const id = "e2e:commands";

    pub const Configuration = struct {
        enabled: bool,
        disabled_command: bool = false,
    };

    pub const Dependencies = struct {
        commands: *commands.Commands,
        players: *vanilla.Players,
        chunks: *vanilla.Chunks,
        menus: *vanilla.Menus,
        dropped: *vanilla.ItemEntities,
        state: *State,
        label: []const u8,
        limit: u32,
        absent: ?u32,
    };

    const Empty = struct {};

    const Choose = struct {
        target: []const u8,
        amount: u32,
    };

    const Mode = struct { mode: enum { creative, survival } };

    const Echo = struct { message: []const u8 };

    const secret_permission: commands.Permission = .{ .name = "probe.secret", .description = "Restricted test command" };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Probe {
        std.debug.assert(deps.absent == null);
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.state.players = deps.players;

        if (config.enabled) {
            const root = try deps.commands.literal(.{ .name = "probe", .description = "Command acceptance checks" });

            if (config.disabled_command)
                _ = try root.add(self, commands.leaf(Probe, Empty, .{
                    .name = "disabled",
                    .description = "Opt-in command",
                    .handler = entry,
                    .arguments = .{},
                }));
            _ = try root.add(self, commands.leaf(Probe, Choose, .{
                .name = "choose",
                .description = "Choose a suggested target",
                .handler = choose,
                .arguments = .{ .target = .{ .suggest = suggest }, .amount = .{ .minimum = 1, .maximum = 7 } },
            }));
            _ = try root.add(self, commands.leaf(Probe, Mode, .{
                .name = "mode",
                .description = "Choose a typed enum",
                .handler = mode,
                .arguments = .{ .mode = .{} },
            }));
            _ = try root.add(self, commands.leaf(Probe, Echo, .{
                .name = "echo",
                .description = "Echo a message",
                .handler = echo,
                .arguments = .{ .message = .{ .greedy = true } },
            }));
            const admin = try root.literal(.{ .name = "admin", .permission = &secret_permission });
            _ = try admin.add(self, commands.leaf(Probe, Empty, .{
                .name = "secret",
                .description = "SECRET_PERMISSION",
                .handler = secret,
                .arguments = .{},
            }));
            _ = try admin.add(self, commands.leaf(Probe, Empty, .{
                .name = "revoke",
                .description = "Revoke access immediately",
                .handler = revoke,
                .arguments = .{},
            }));

            inline for (.{ "one", "two", "three", "four", "five", "six", "seven" }) |name|
                _ = try root.add(self, commands.leaf(Probe, Empty, .{
                    .name = name,
                    .description = "Pagination entry",
                    .handler = entry,
                    .arguments = .{},
                }));
        }

        return self;
    }

    fn choose(self: *Probe, context: commands.Context, args: Choose) !void {
        std.debug.assert(args.amount <= self.deps.limit);
        var buffer: [160]u8 = undefined;
        context.reply(try std.fmt.bufPrint(&buffer, "choice {s}={d} / {s}", .{ args.target, args.amount, self.deps.label }));
    }

    fn mode(_: *Probe, context: commands.Context, args: Mode) !void {
        context.reply(@tagName(args.mode));
    }

    fn echo(_: *Probe, context: commands.Context, args: Echo) !void {
        context.reply(args.message);
    }

    fn secret(_: *Probe, context: commands.Context, _: Empty) !void {
        context.reply("secret granted");
    }

    fn revoke(self: *Probe, context: commands.Context, _: Empty) !void {
        self.deps.state.enabled = false;
        context.reply("access revoked");
    }

    fn entry(_: *Probe, context: commands.Context, _: Empty) !void {
        context.reply("entry executed");
    }

    fn suggest(_: *Probe, context: commands.CompletionContext, output: *commands.Suggestions) void {
        std.debug.assert(std.mem.eql(u8, context.argument, "target"));

        for ([_][]const u8{ "alpha", "amber", "beta" }) |name| {
            if (!std.mem.startsWith(u8, name, context.prefix)) continue;

            var tooltip: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&tooltip, "Custom target: {s}", .{name}) catch unreachable;
            output.add(.{ .text = name, .tooltip = text }) catch return;
        }
    }
};
