const std = @import("std");
const vanilla = @import("vanilla");
const sessions = @import("sessions");
const lightning_rod = @import("lightning_rod");
const catalog = @import("catalog.zig");

pub const IslandCommands = struct {
    pub const id = catalog.island_namespace;
    pub const Configuration = struct { catalog: *catalog.Catalog, routing: *sessions.Routing, index: usize };
    pub const Dependencies = struct {
        commands: *vanilla.commands.Commands,
        players: *vanilla.Players,
        sessions: *sessions.Service,
        chat: *vanilla.Chat,
        storage: lightning_rod.storage.Space,
    };
    const None = struct {};
    const Player = struct { player: u128 };
    const Kick = struct { player: ?u128 = null };

    deps: Dependencies,
    config: Configuration,
    saved: catalog.State,
    cursor: catalog.Cursor = .{},

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*IslandCommands {
        const self = try allocate(allocator, deps, config);
        self.saved = try catalog.State.read(deps.storage);
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*IslandCommands {
        const self = try allocator.create(IslandCommands);
        self.* = .{ .deps = deps, .config = config, .saved = .{} };
        inline for (.{ "island", "is" }) |name| {
            const island = try deps.commands.register(self, vanilla.commands.leaf(IslandCommands, None, .{
                .name = name,
                .description = "Travel to your home island",
                .handler = home,
                .arguments = .{},
            }));
            _ = try island.add(self, vanilla.commands.leaf(IslandCommands, None, .{
                .name = "create",
                .description = "Create your home island",
                .handler = create,
                .arguments = .{},
            }));
            _ = try island.add(self, vanilla.commands.leaf(IslandCommands, None, .{
                .name = "home",
                .description = "Travel to your home island",
                .handler = home,
                .arguments = .{},
            }));
            _ = try island.add(self, vanilla.commands.leaf(IslandCommands, Player, .{
                .name = "invite",
                .description = "Invite a player to join your island",
                .handler = invite,
                .arguments = .{ .player = .{ .parse = parsePlayer, .suggest = suggestPlayers } },
            }));
            _ = try island.add(self, vanilla.commands.leaf(IslandCommands, Player, .{
                .name = "accept",
                .description = "Accept an island owner's invitation",
                .handler = accept,
                .arguments = .{ .player = .{ .parse = parsePlayer, .suggest = suggestPlayers } },
            }));
        }
        const visits = try deps.commands.register(self, vanilla.commands.leaf(IslandCommands, Player, .{
            .name = "visit",
            .description = "Visit another player's home island",
            .handler = visit,
            .arguments = .{ .player = .{ .parse = parsePlayer, .suggest = suggestPlayers } },
        }));
        _ = try visits.add(self, vanilla.commands.leaf(IslandCommands, Player, .{
            .name = "accept",
            .description = "Accept a visit request",
            .handler = acceptVisit,
            .arguments = .{ .player = .{ .parse = parsePlayer, .suggest = suggestPlayers } },
        }));
        _ = try deps.commands.register(self, vanilla.commands.leaf(IslandCommands, None, .{
            .name = "hub",
            .description = "Return to the hub",
            .handler = hub,
            .arguments = .{},
        }));
        _ = try deps.commands.register(self, vanilla.commands.leaf(IslandCommands, Kick, .{
            .name = "kick",
            .description = "Return to the hub or send a visitor there",
            .handler = kick,
            .arguments = .{ .player = .{ .parse = parsePlayer, .suggest = suggestPlayers } },
        }));
        return self;
    }

    fn member(self: *IslandCommands, uuid: u128) ?catalog.Member {
        const player = self.deps.players.find(uuid) orelse return null;
        return catalog.Member.named(uuid, player.name[0..player.name_len]);
    }

    fn create(self: *IslandCommands, context: vanilla.commands.Context, _: None) !void {
        const owner = self.member(context.sender) orelse return;
        _ = self.config.catalog.create(owner) catch |err| {
            context.reply(failure(err));
            return;
        };
    }

    fn home(self: *IslandCommands, context: vanilla.commands.Context, _: None) !void {
        self.config.catalog.requestHome(context.sender) catch |err| {
            context.reply(failure(err));
            return;
        };
    }

    fn invite(self: *IslandCommands, context: vanilla.commands.Context, args: Player) !void {
        self.config.catalog.invite(context.sender, args.player) catch |err| {
            context.reply(failure(err));
            return;
        };
        context.reply("Invitation sent.");
    }

    fn accept(self: *IslandCommands, context: vanilla.commands.Context, args: Player) !void {
        const player = self.member(context.sender) orelse return;
        self.config.catalog.accept(player, args.player) catch |err| {
            context.reply(failure(err));
            return;
        };
    }

    fn visit(self: *IslandCommands, context: vanilla.commands.Context, args: Player) !void {
        const requested = self.config.catalog.visit(context.sender, args.player) catch |err| {
            context.reply(failure(err));
            return;
        };
        if (requested) context.reply("Visit request sent.");
    }

    fn acceptVisit(self: *IslandCommands, context: vanilla.commands.Context, args: Player) !void {
        self.config.catalog.acceptVisit(context.sender, args.player) catch |err| {
            context.reply(failure(err));
            return;
        };
        context.reply("Visit accepted.");
    }

    fn hub(self: *IslandCommands, context: vanilla.commands.Context, _: None) !void {
        try self.kick(context, .{});
    }

    fn kick(self: *IslandCommands, context: vanilla.commands.Context, args: Kick) !void {
        self.config.catalog.kick(context.sender, args.player) catch |err| {
            context.reply(failure(err));
            return;
        };
        if (args.player != null) context.reply("Visitor sent to hub.");
    }

    fn parsePlayer(self: *IslandCommands, _: vanilla.commands.Context, name: []const u8) vanilla.commands.ParseError!u128 {
        const player = self.config.catalog.find(name) orelse return error.InvalidArgument;
        return player.uuid;
    }

    fn suggestPlayers(self: *IslandCommands, context: vanilla.commands.CompletionContext, output: *vanilla.commands.Suggestions) void {
        var members: [catalog.maximum_players + catalog.maximum * catalog.maximum_members]catalog.Member = undefined;
        const count = self.config.catalog.list(&members);
        for (members[0..count]) |player| {
            const name = player.name[0..player.name_len];
            if (std.ascii.startsWithIgnoreCase(name, context.prefix)) output.add(.{ .text = name }) catch return;
        }
    }

    pub fn tick(self: *IslandCommands) !void {
        const directory = self.config.catalog;
        for (self.deps.sessions.input_events) |event| switch (event) {
            .joined => |joined| {
                try directory.arrive(self.config.index, catalog.Member.named(joined.uuid, joined.name[0..joined.name_len]), joined.handle);
            },
            .left => |handle| directory.depart(self.config.index, handle),
            else => {},
        };
        var selected: [catalog.maximum_players]catalog.Player = undefined;
        var updates: [catalog.maximum_players]catalog.Update = undefined;
        var count: usize = 0;
        for (self.deps.players.records) |player| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready or !player.loaded or player.configuring) continue;
            selected[count] = .{ .uuid = player.uuid, .handle = handle };
            count += 1;
        }
        if (!directory.poll(self.config.index, selected[0..count], updates[0..count], &self.cursor)) return;
        for (selected[0..count], updates[0..count]) |player, update| {
            const handle = player.handle;
            if (update.notice) |notice| self.deps.chat.system(handle, switch (notice) {
                .created => "Island created. Travelling home.",
                .joined => "Joined island. Travelling home.",
                .home => "Travelling home.",
                .visit => "Visiting island.",
                .hub => "Returning to hub.",
            });
            if (update.invitation) |owner| {
                var buffer: [128]u8 = undefined;
                var command: [64]u8 = undefined;
                self.deps.chat.systemAction(handle, try std.fmt.bufPrint(&buffer, "Invitation from {s}. [Accept]", .{owner.name[0..owner.name_len]}), .{
                    .command = try std.fmt.bufPrint(&command, "/is accept {s}", .{owner.name[0..owner.name_len]}),
                    .hover = "Click to join this island and make it your home.",
                });
            }
            if (update.visitor) |visitor| {
                var buffer: [128]u8 = undefined;
                var command: [64]u8 = undefined;
                self.deps.chat.systemAction(handle, try std.fmt.bufPrint(&buffer, "{s} wants to visit your island. [Accept]", .{visitor.name[0..visitor.name_len]}), .{
                    .command = try std.fmt.bufPrint(&command, "/visit accept {s}", .{visitor.name[0..visitor.name_len]}),
                    .hover = "Click to let this player visit your island.",
                });
            }
            const target = update.destination orelse continue;
            if (target == self.config.index) {
                directory.moved(player.uuid, self.config.index, target);
                try self.deps.players.teleport(&self.deps.players.records[handle.index], self.deps.players.spawn_world, self.deps.players.config.spawn, .{ .yaw = 0, .pitch = 0 });
                continue;
            }
            self.deps.sessions.transfer(handle, self.config.routing.endpoints[target]) catch |err| switch (err) {
                error.Busy => continue,
                error.Closed, error.Backpressured => {
                    const notice = directory.cancelMove(player.uuid, target);
                    self.deps.chat.system(handle, if (notice == .created) "Island created, but destination is unavailable or full." else if (notice == .joined) "Joined island, but destination is unavailable or full." else "Destination is unavailable or full.");
                    continue;
                },
                error.InvalidDestination => return err,
            };
            directory.moved(player.uuid, self.config.index, target);
        }
    }

    pub fn checkpoint(self: *IslandCommands, space: lightning_rod.storage.Space) !void {
        const state = self.config.catalog.snapshot(self.config.index);
        if (std.meta.eql(state, self.saved)) return;
        try state.write(space);
        self.saved = state;
    }
};

fn failure(err: catalog.Error) []const u8 {
    return switch (err) {
        error.AlreadyMember => "You already belong to an island.",
        error.TargetAlreadyMember => "That player already belongs to an island.",
        error.IslandLimit => "The island limit has been reached.",
        error.NoIsland => "No home island found.",
        error.NotOwner => "Only the island owner can do that.",
        error.PlayerOffline => "That player is not online.",
        error.IslandFull => "That island has no free membership slots.",
        error.NoInvitation => "You have no invitation from that owner.",
        error.NoVisitRequest => "No visit request from that player.",
        error.NotVisiting => "That player is not visiting your island.",
        error.CannotKickMember => "Island members cannot be kicked as visitors.",
        error.ProfileLimit => "The player directory is full.",
    };
}
