const std = @import("std");
const lightning_rod = @import("lightning_rod");

const max_webhook_url_bytes = 2_048;
const max_payload_bytes = 256;

pub const SendJob = struct {
    webhook_url: [max_webhook_url_bytes]u8 = undefined,
    webhook_url_len: u16 = 0,
    payload: [max_payload_bytes]u8 = undefined,
    payload_len: u16 = 0,

    pub fn url(self: *const SendJob) []const u8 {
        return self.webhook_url[0..self.webhook_url_len];
    }

    pub fn body(self: *const SendJob) []const u8 {
        return self.payload[0..self.payload_len];
    }
};

pub const TaskScheduler = struct {
    context: *anyopaque,
    stage_fn: *const fn (*anyopaque, SendJob) bool,

    pub fn stage(self: TaskScheduler, job: SendJob) bool {
        return self.stage_fn(self.context, job);
    }
};

pub const Discord = struct {
    pub const id = "lightning_rod:discord_webhook";
    pub const Configuration = struct {
        webhook_url: []const u8,
        scheduler: TaskScheduler,
        queue_capacity: usize = 64,

        pub fn validate(self: Configuration) !void {
            if (self.webhook_url.len == 0 or self.webhook_url.len > max_webhook_url_bytes)
                return error.InvalidWebhookUrl;
            const uri = try std.Uri.parse(self.webhook_url);
            if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http"))
                return error.InvalidWebhookUrl;
            if (self.queue_capacity == 0) return error.InvalidQueueCapacity;
        }
    };
    pub const Dependencies = struct {
        players: *lightning_rod.players.Players,
        lifecycle: *lightning_rod.player_lifecycle.Events,
    };

    deps: Dependencies,
    config: Configuration,
    webhook_url: []u8,
    queue: []SendJob,
    read: usize = 0,
    write: usize = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Discord {
        try configuration.validate();
        const self = try allocator.create(Discord);
        self.* = .{
            .deps = deps,
            .config = configuration,
            .webhook_url = try allocator.dupe(u8, configuration.webhook_url),
            .queue = try allocator.alloc(SendJob, configuration.queue_capacity),
        };
        return self;
    }

    pub fn tick(self: *Discord, _: std.mem.Allocator) void {
        // enqueue joined
        for (self.deps.lifecycle.joined.values) |event| {
            const player = &self.deps.players.records[event.slot];
            self.enqueue(player.name_slice(), " joined the game");
        }

        // enqueue left
        for (self.deps.lifecycle.left.values) |event| {
            const player = &self.deps.players.records[event.slot];
            self.enqueue(player.name_slice(), " left the game");
        }

        // flush
        while (self.read != self.write) {
            if (!self.config.scheduler.stage(self.queue[self.read % self.queue.len])) return;
            self.read += 1;
        }
    }

    fn enqueue(self: *Discord, name: []const u8, suffix: []const u8) void {
        if (self.write - self.read == self.queue.len) return;
        const job = formatJob(self.webhook_url, name, suffix) catch return;
        self.queue[self.write % self.queue.len] = job;
        self.write += 1;
    }
};

fn formatJob(webhook_url: []const u8, name: []const u8, suffix: []const u8) !SendJob {
    var job = SendJob{};
    if (webhook_url.len > job.webhook_url.len) return error.InvalidWebhookUrl;
    @memcpy(job.webhook_url[0..webhook_url.len], webhook_url);
    job.webhook_url_len = @intCast(webhook_url.len);
    const body = try std.fmt.bufPrint(&job.payload, "{{\"content\":\"{s}{s}\"}}", .{ name, suffix });
    job.payload_len = @intCast(body.len);
    return job;
}
