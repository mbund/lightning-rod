//! Asks Mojang's session server whether players joined, many at once, without the sessions thread
//! waiting: each question is a task on the server's I/O, concurrent with everything else, that
//! writes the answer to its connection's slot and wakes the connection.
const std = @import("std");
const sessions = @import("sessions");

pub const Authenticator = struct {
    /// What Mojang knows of a player who joined: their UUID, their name as Mojang spells it, and
    /// the signed textures property naming their skin and cape.
    pub const Profile = struct {
        uuid: u128,
        name: [16]u8 = undefined,
        name_len: u8 = 0,
        textures_value: [sessions.PlayerProfile.value_max]u8 = undefined,
        textures_value_len: u16 = 0,
        textures_signature: [sessions.PlayerProfile.signature_max]u8 = undefined,
        textures_signature_len: u16 = 0,

        pub fn nameText(self: *const Profile) []const u8 {
            return self.name[0..self.name_len];
        }
    };

    pub const Answer = union(enum) {
        joined: Profile,
        /// Mojang has no record of the player joining with this hash.
        unverified,
        /// Mojang could not be asked, or answered something unexpected.
        unavailable,
    };

    const State = enum(u8) { idle, asking, answered };

    const Slot = struct {
        state: std.atomic.Value(State) = .init(.idle),
        /// The connection the question is for; one that left leaves its answer to be dropped.
        handle: sessions.Handle = .{ .index = 0, .generation = 0 },
        url: [url_max]u8 = undefined,
        url_len: usize = 0,
        answer: Answer = undefined,
    };

    const url_max = 256;
    /// A hasJoined answer is a couple of kilobytes; this leaves room for more properties.
    const response_max = 16 * 1024;

    io: std.Io,
    client: std.http.Client,
    group: std.Io.Group = .init,
    slots: []Slot,
    wake: *const sessions.Wake,
    session_host: []const u8,
    /// How long a question may take before the player is told the servers are down.
    timeout: std.Io.Duration = .fromSeconds(10),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, connections: usize, wake: *const sessions.Wake, session_host: []const u8) !*Authenticator {
        const self = try allocator.create(Authenticator);
        // A slot per connection holds an answer of a few kilobytes, more than plugin memory
        // holds for a full server, so slots take pages of their own, once, at startup.
        const slots = try std.heap.page_allocator.alloc(Slot, connections);
        for (slots) |*slot| slot.* = .{};
        // The client allocates as connections come and go, on whichever thread asks, so it
        // takes a thread safe allocator of its own rather than the plugin's sealed memory.
        self.* = .{ .io = io, .client = .{ .allocator = std.heap.smp_allocator, .io = io }, .slots = slots, .wake = wake, .session_host = session_host };
        return self;
    }

    /// Stops the questions still out and lets go of their connections.
    pub fn close(self: *Authenticator) void {
        self.group.cancel(self.io);
        self.client.deinit();
        std.heap.page_allocator.free(self.slots);
    }

    /// Starts asking whether the player joined with this hash. The answer comes later, from
    /// `answer`, once the connection is woken.
    pub fn ask(self: *Authenticator, handle: sessions.Handle, name: []const u8, server_hash: [20]u8) !void {
        const slot = &self.slots[handle.index];
        // A connection gone before its answer came still holds the slot until it does.
        if (slot.state.load(.acquire) != .idle) return error.SlotBusy;
        var digest: [41]u8 = undefined;
        var url: std.Io.Writer = .fixed(&slot.url);
        // Offline clients may send any name; escaping keeps it one query value.
        url.print("{s}/session/minecraft/hasJoined?username=", .{self.session_host}) catch return error.UrlTooLong;
        std.Uri.Component.percentEncode(&url, name, isUnreserved) catch return error.UrlTooLong;
        url.print("&serverId={s}", .{minecraftDigest(server_hash, &digest)}) catch return error.UrlTooLong;
        slot.url_len = url.buffered().len;
        slot.handle = handle;
        slot.state.store(.asking, .release);
        self.group.concurrent(self.io, run, .{ self, slot }) catch |err| {
            slot.state.store(.idle, .release);
            return err;
        };
    }

    /// The answer for the connection once Mojang gave one. Answers for connections that left are
    /// dropped as they are found, freeing their slot.
    pub fn answer(self: *Authenticator, handle: sessions.Handle) ?Answer {
        const slot = &self.slots[handle.index];
        if (slot.state.load(.acquire) != .answered) return null;
        const result = slot.answer;
        const for_this = slot.handle.generation == handle.generation;
        slot.state.store(.idle, .release);
        return if (for_this) result else null;
    }

    fn run(self: *Authenticator, slot: *Slot) std.Io.Cancelable!void {
        // The question races a timer; whichever ends first stops the other.
        const Outcome = union(enum) { fetched: Answer, expired: std.Io.Cancelable!void };
        var outcomes: [2]Outcome = undefined;
        var select = std.Io.Select(Outcome).init(self.io, &outcomes);
        defer select.cancelDiscard();
        select.concurrent(.fetched, fetchAnswer, .{ self, slot }) catch {
            slot.answer = .unavailable;
            return self.answered(slot);
        };
        select.concurrent(.expired, std.Io.sleep, .{ self.io, self.timeout, .awake }) catch {};
        slot.answer = switch (try select.await()) {
            .fetched => |value| value,
            .expired => .unavailable,
        };
        self.answered(slot);
    }

    fn answered(self: *Authenticator, slot: *Slot) void {
        slot.state.store(.answered, .release);
        self.wake.connection(slot.handle);
    }

    fn fetchAnswer(self: *Authenticator, slot: *Slot) Answer {
        return self.fetch(slot) catch .unavailable;
    }

    fn fetch(self: *Authenticator, slot: *Slot) !Answer {
        var response: [response_max]u8 = undefined;
        var body: std.Io.Writer = .fixed(&response);
        var redirect: [1024]u8 = undefined;
        const result = try self.client.fetch(.{
            .location = .{ .url = slot.url[0..slot.url_len] },
            .response_writer = &body,
            .redirect_buffer = &redirect,
            .headers = .{ .user_agent = .{ .override = "lightning-rod" } },
        });
        return switch (result.status) {
            .ok => parseJoined(body.buffered()),
            .no_content => .unverified,
            else => .unavailable,
        };
    }
};

/// A hasJoined answer: the profile, or `unavailable` for anything not shaped like one.
pub fn parseJoined(json: []const u8) Authenticator.Answer {
    var scratch: [Authenticator.response_max]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const Property = struct { name: []const u8, value: []const u8, signature: ?[]const u8 = null };
    const Response = struct { id: []const u8, name: []const u8, properties: []const Property = &.{} };
    const parsed = std.json.parseFromSliceLeaky(Response, fixed.allocator(), json, .{ .ignore_unknown_fields = true }) catch return .unavailable;
    if (parsed.id.len != 32 or parsed.name.len == 0 or parsed.name.len > 16) return .unavailable;
    var profile: Authenticator.Profile = .{ .uuid = std.fmt.parseInt(u128, parsed.id, 16) catch return .unavailable };
    @memcpy(profile.name[0..parsed.name.len], parsed.name);
    profile.name_len = @intCast(parsed.name.len);
    for (parsed.properties) |property| {
        if (!std.mem.eql(u8, property.name, "textures")) continue;
        const signature = property.signature orelse "";
        if (property.value.len > profile.textures_value.len or signature.len > profile.textures_signature.len) return .unavailable;
        @memcpy(profile.textures_value[0..property.value.len], property.value);
        profile.textures_value_len = @intCast(property.value.len);
        @memcpy(profile.textures_signature[0..signature.len], signature);
        profile.textures_signature_len = @intCast(signature.len);
    }
    return .{ .joined = profile };
}

/// A SHA-1 digest as Minecraft writes it: the twenty bytes read as one signed big-endian number,
/// in lowercase hex, without leading zeros, negative ones with a minus sign.
pub fn minecraftDigest(digest: [20]u8, output: *[41]u8) []const u8 {
    var magnitude = std.mem.readInt(u160, &digest, .big);
    const negative = magnitude >> 159 != 0;
    if (negative) magnitude = (~magnitude) +% 1;
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x:0>40}", .{magnitude}) catch unreachable;
    const first = std.mem.indexOfNone(u8, &hex, "0") orelse hex.len - 1;
    var at: usize = 0;
    if (negative) {
        output[0] = '-';
        at = 1;
    }
    @memcpy(output[at..][0 .. hex.len - first], hex[first..]);
    return output[0 .. at + hex.len - first];
}

test "digests read as signed numbers, as Minecraft writes them" {
    // The examples wiki.vg gives for SHA-1 of a name.
    const cases = [_]struct { name: []const u8, expected: []const u8 }{
        .{ .name = "Notch", .expected = "4ed1f46bbe04bc756bcb17c0c7ce3e4632f06a48" },
        .{ .name = "jeb_", .expected = "-7c9d5b0044c130109a5d7b5fb5c317c02b4e28c1" },
        .{ .name = "simon", .expected = "88e16a1019277b15d58faf0541e11910eb756f6" },
    };
    for (cases) |case| {
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(case.name, &digest, .{});
        var output: [41]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, minecraftDigest(digest, &output));
    }
}

test "a joined answer yields the profile and its signed textures" {
    const json =
        \\{"id":"069a79f444e94726a5befca90e38aaf5","name":"Notch","properties":[{"name":"textures","value":"eyJ0ZXh0dXJlcyI6e319","signature":"c2lnbmVk"}],"profileActions":[]}
    ;
    const answer = parseJoined(json);
    try std.testing.expect(answer == .joined);
    const profile = answer.joined;
    try std.testing.expectEqual(@as(u128, 0x069a79f444e94726a5befca90e38aaf5), profile.uuid);
    try std.testing.expectEqualStrings("Notch", profile.nameText());
    try std.testing.expectEqualStrings("eyJ0ZXh0dXJlcyI6e319", profile.textures_value[0..profile.textures_value_len]);
    try std.testing.expectEqualStrings("c2lnbmVk", profile.textures_signature[0..profile.textures_signature_len]);
    try std.testing.expect(parseJoined("{\"id\":\"short\",\"name\":\"x\"}") == .unavailable);
    try std.testing.expect(parseJoined("not json") == .unavailable);
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// Answers hasJoined as Mojang would: Notch joined, slow takes too long, anyone else did not.
const FakeSessionServer = struct {
    listener: std.Io.net.Server,
    group: std.Io.Group = .init,

    fn serve(self: *FakeSessionServer, io: std.Io) std.Io.Cancelable!void {
        while (true) {
            const stream = self.listener.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            self.group.concurrent(io, connection, .{ io, stream }) catch stream.close(io);
        }
    }

    fn connection(io: std.Io, stream: std.Io.net.Stream) std.Io.Cancelable!void {
        defer stream.close(io);
        var input: [4096]u8 = undefined;
        var output: [4096]u8 = undefined;
        var reader = stream.reader(io, &input);
        var writer = stream.writer(io, &output);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        while (true) {
            var request = server.receiveHead() catch return;
            const target = request.head.target;
            if (std.mem.indexOf(u8, target, "username=slow&") != null) {
                try io.sleep(.fromSeconds(30), .awake);
            } else if (std.mem.indexOf(u8, target, "username=Notch&serverId=") != null) {
                request.respond(
                    \\{"id":"069a79f444e94726a5befca90e38aaf5","name":"Notch","properties":[{"name":"textures","value":"dGV4dHVyZXM=","signature":"c2ln"}]}
                , .{}) catch return;
            } else {
                request.respond("", .{ .status = .no_content }) catch return;
            }
        }
    }
};

test "asks a session server for many players at once" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var fake: FakeSessionServer = .{ .listener = try address.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(FakeSessionServer.serve, .{ &fake, io });
    defer {
        serving.cancel(io) catch {};
        fake.group.cancel(io);
    }

    var host: [64]u8 = undefined;
    const session_host = try std.fmt.bufPrint(&host, "http://127.0.0.1:{d}", .{fake.listener.socket.address.getPort()});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const wake: sessions.Wake = .{};
    const authenticator = try Authenticator.init(arena.allocator(), io, 4, &wake, session_host);
    defer authenticator.close();
    authenticator.timeout = .fromMilliseconds(500);

    const notch: sessions.Handle = .{ .index = 0, .generation = 1 };
    const nobody: sessions.Handle = .{ .index = 1, .generation = 1 };
    const slow: sessions.Handle = .{ .index = 2, .generation = 1 };
    const hash: [20]u8 = @splat(0xab);
    try authenticator.ask(notch, "Notch", hash);
    try authenticator.ask(nobody, "nobody", hash);
    try authenticator.ask(slow, "slow", hash);
    try std.testing.expectError(error.SlotBusy, authenticator.ask(notch, "Notch", hash));

    var answers: [3]?Authenticator.Answer = @splat(null);
    const handles = [_]sessions.Handle{ notch, nobody, slow };
    var waited: usize = 0;
    while (answers[0] == null or answers[1] == null or answers[2] == null) : (waited += 1) {
        if (waited == 500) return error.NoAnswer;
        for (handles, &answers) |handle, *slot| {
            if (slot.* == null) slot.* = authenticator.answer(handle);
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const profile = answers[0].?.joined;
    try std.testing.expectEqual(@as(u128, 0x069a79f444e94726a5befca90e38aaf5), profile.uuid);
    try std.testing.expectEqualStrings("dGV4dHVyZXM=", profile.textures_value[0..profile.textures_value_len]);
    try std.testing.expect(answers[1].? == .unverified);
    try std.testing.expect(answers[2].? == .unavailable);
    // An answer is taken once, and the slot is free for the next question.
    try std.testing.expect(authenticator.answer(notch) == null);
    try authenticator.ask(.{ .index = 0, .generation = 2 }, "nobody", hash);
}
