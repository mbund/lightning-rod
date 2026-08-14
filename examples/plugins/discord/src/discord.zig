const std = @import("std");
const lightning_rod = @import("lightning_rod");

const max_webhook_url_bytes = 2_048;
const max_payload_bytes = 256;
const DebugAllocator = std.heap.DebugAllocator(.{ .backing_allocator_zeroes = false });

pub const Config = struct {
    webhook_url: []const u8,
    queue_capacity: usize = 64,
    io_memory_bytes: usize = 8 * 1024 * 1024,

    pub fn validate(self: Config) !void {
        if (self.webhook_url.len == 0 or self.webhook_url.len > max_webhook_url_bytes)
            return error.InvalidWebhookUrl;
        const uri = try std.Uri.parse(self.webhook_url);
        const scheme = uri.scheme;
        if (!std.mem.eql(u8, scheme, "https") and !std.mem.eql(u8, scheme, "http"))
            return error.InvalidWebhookUrl;
        if (self.queue_capacity == 0) return error.InvalidQueueCapacity;
        if (self.io_memory_bytes < 1024 * 1024) return error.InvalidIoMemoryCapacity;
    }
};

const Message = struct {
    length: u16 = 0,
    bytes: [max_payload_bytes]u8 = undefined,

    fn slice(self: *const Message) []const u8 {
        return self.bytes[0..self.length];
    }
};

pub const Discord = struct {
    pub const id = "lightning_rod:discord_webhook";

    players: *lightning_rod.players.Players,
    lifecycle: *lightning_rod.player_lifecycle.Events,
    webhook_url: []const u8,
    queue: []Message,
    io_memory: []u8,
    io_fixed: std.heap.FixedBufferAllocator,
    io_debug: DebugAllocator,
    read_sequence: std.atomic.Value(usize) = .init(0),
    write_sequence: std.atomic.Value(usize) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    worker: std.Io.Group = .init,
    threaded: std.Io.Threaded = undefined,
    started: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        players: *lightning_rod.players.Players,
        lifecycle: *lightning_rod.player_lifecycle.Events,
        discord_config: Config,
    ) !*Discord {
        try discord_config.validate();
        const self = try allocator.create(Discord);
        const io_memory = try allocator.alloc(u8, discord_config.io_memory_bytes);
        self.* = .{
            .players = players,
            .lifecycle = lifecycle,
            .webhook_url = try allocator.dupe(u8, discord_config.webhook_url),
            .queue = try allocator.alloc(Message, discord_config.queue_capacity),
            .io_memory = io_memory,
            .io_fixed = std.heap.FixedBufferAllocator.init(io_memory),
            .io_debug = .init,
        };
        self.io_debug.backing_allocator = self.io_fixed.allocator();
        return self;
    }

    pub fn joined(self: *Discord) void {
        for (self.lifecycle.joined.values) |event| {
            const player = &self.players.records[event.slot];
            self.enqueue(player.name_slice(), " joined the game");
        }
    }

    pub fn left(self: *Discord) void {
        for (self.lifecycle.left.values) |event| {
            const player = &self.players.records[event.slot];
            self.enqueue(player.name_slice(), " left the game");
        }
    }

    pub fn tick(self: *Discord, _: std.mem.Allocator) void {
        if (self.started) return;
        self.threaded = std.Io.Threaded.init(self.io_debug.allocator(), .{
            .async_limit = .limited(1),
            .concurrent_limit = .limited(1),
        });
        self.started = true;
        self.worker.async(self.threaded.io(), runWorker, .{self});
    }

    pub fn deinit(self: *Discord) void {
        if (self.started) {
            self.stopping.store(true, .release);
            self.worker.cancel(self.threaded.io());
            self.threaded.deinit();
            self.started = false;
        }
        std.debug.assert(self.io_debug.deinit() == .ok);
    }

    fn enqueue(self: *Discord, name: []const u8, suffix: []const u8) void {
        const write = self.write_sequence.load(.monotonic);
        const read = self.read_sequence.load(.acquire);
        if (write -% read == self.queue.len) {
            std.log.warn("event=discord_webhook_dropped reason=queue_full", .{});
            return;
        }
        const message = &self.queue[write % self.queue.len];
        message.* = formatMessage(name, suffix) catch {
            std.log.warn("event=discord_webhook_dropped reason=message_too_long", .{});
            return;
        };
        self.write_sequence.store(write +% 1, .release);
    }
};

fn runWorker(self: *Discord) std.Io.Cancelable!void {
    const io = self.threaded.io();
    var client = std.http.Client{ .allocator = self.io_debug.allocator(), .io = io };
    defer client.deinit();
    while (!self.stopping.load(.acquire)) {
        const read = self.read_sequence.load(.monotonic);
        if (read == self.write_sequence.load(.acquire)) {
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
            continue;
        }
        const message = self.queue[read % self.queue.len];
        self.read_sequence.store(read +% 1, .release);
        const result = client.fetch(.{
            .location = .{ .url = self.webhook_url },
            .method = .POST,
            .payload = message.slice(),
            .headers = .{ .content_type = .{ .override = "application/json" } },
        }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.warn("event=discord_webhook_failed error={s}", .{@errorName(err)});
            continue;
        };
        if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300)
            std.log.warn("event=discord_webhook_rejected status={}", .{@intFromEnum(result.status)});
    }
}

fn formatMessage(name: []const u8, suffix: []const u8) !Message {
    var result = Message{};
    const payload = try std.fmt.bufPrint(&result.bytes, "{{\"content\":\"{s}{s}\"}}", .{ name, suffix });
    result.length = @intCast(payload.len);
    return result;
}

test "webhook messages use Discord JSON content" {
    const message = try formatMessage("player_name", " joined the game");
    try std.testing.expectEqualStrings(
        "{\"content\":\"player_name joined the game\"}",
        message.slice(),
    );
}

test "configuration rejects non-HTTP webhook URLs" {
    try std.testing.expectError(
        error.InvalidWebhookUrl,
        (Config{ .webhook_url = "file:///tmp/webhook" }).validate(),
    );
}

test "all plugin declarations compile" {
    _ = &Discord.create;
    _ = &Discord.joined;
    _ = &Discord.left;
    _ = &Discord.tick;
    _ = &Discord.deinit;
    _ = &runWorker;
}
