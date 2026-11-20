//! Asks Mojang's session server whether players joined, without the sessions thread waiting.
//!
//! Each question is a task on an I/O of its own, `std.Io.Threaded`, asking with `std.http.Client`
//! and keeping its connections alive between questions. At most `questions` run at once; the
//! rest wait in a queue the running tasks drain. Everything the I/O and the client allocate comes
//! from one region reserved at startup and handed out by a buddy allocator, so the memory has a
//! maximum, exists before the first login, and is poisoned as it is freed. The root certificates
//! are read into it at startup rather than at the first login.
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const BuddyAllocator = lightning_rod.system.BuddyAllocator;

pub const Options = struct {
    /// Where hasJoined is asked: `https://host[:port]`, or `http://` for a local stand in.
    session_host: []const u8,
    /// Questions asked at once; the rest wait their turn. Each takes two threads while it runs,
    /// the question and its request, which stay parked for the next once started.
    questions: u16 = 4,
    /// How long a question may take before the player is told the servers are down.
    timeout: std.Io.Duration = .fromSeconds(10),
    /// The most the system's root certificates may take, kept apart from what the client
    /// allocates as it runs. 121 certificates took 132 KiB in November 2026.
    certificate_bytes: usize = 256 * 1024,
    /// Each thread's stack, which the system backs as it is touched.
    stack_bytes: usize = 2 * 1024 * 1024,
};

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
        /// Mojang could not be asked in time, or answered something unexpected.
        unavailable,
    };

    const State = enum(u8) { idle, queued, answered };

    const Slot = struct {
        state: std.atomic.Value(State) = .init(.idle),
        /// The connection the question is for; one that left leaves its answer to be dropped.
        handle: sessions.Handle = .{ .index = 0, .generation = 0 },
        name: [16]u8 = undefined,
        name_len: u8 = 0,
        server_id: [41]u8 = undefined,
        server_id_len: u8 = 0,
        answer: Answer = undefined,
    };

    /// A hasJoined answer is about a kilobyte and a half; this leaves room for more properties.
    const response_max = 16 * 1024;
    /// What parsing an answer of `response_max` bytes may take.
    const scratch_max = 32 * 1024;
    const url_max = 512;

    server_io: std.Io,
    wake: *const sessions.Wake,
    timeout: std.Io.Duration,
    questions: u16,
    host_bytes: [256]u8 = undefined,
    host_len: usize = 0,
    buddy: BuddyAllocator,
    threaded: std.Io.Threaded,
    client: std.http.Client,
    tasks: std.Io.Group = .init,
    slots: []Slot,
    /// Questions waiting for a running task, oldest first; guarded by `mutex` with `running`.
    pending: []u32,
    pending_head: usize = 0,
    pending_len: usize = 0,
    running: u16 = 0,
    mutex: std.Io.Mutex = .init,

    /// What the client allocates for one question, with room to spare. Measured against Mojang
    /// in November 2026: a 59,815 byte TLS connection in a 64 KiB block, kept for the next
    /// question; a 3,248 byte record for the request's task in a 4 KiB block; and a few small
    /// records, about 69 KiB in all.
    const question_bytes = 128 * 1024;

    /// The region the client allocates from: room for every question at once.
    pub fn regionBytes(questions: u16) usize {
        return std.math.ceilPowerOfTwoAssert(usize, @as(usize, questions) * question_bytes);
    }

    /// What `init` allocates, for the plugin to declare.
    pub fn memoryBytes(options: Options, connections: usize) usize {
        // Each allocation carries the plugin allocator's bookkeeping and alignment.
        const slack = 4 * 1024 + std.heap.page_size_min;
        const certificates = if (std.mem.startsWith(u8, options.session_host, "https:")) options.certificate_bytes else 0;
        return @sizeOf(Authenticator) + connections * (@sizeOf(Slot) + @sizeOf(u32)) + regionBytes(options.questions) + BuddyAllocator.bitWords(regionBytes(options.questions)) * @sizeOf(usize) + certificates + slack;
    }

    pub fn init(allocator: std.mem.Allocator, server_io: std.Io, options: Options, connections: usize, wake: *const sessions.Wake) !*Authenticator {
        if (options.questions == 0) return error.NoConcurrentQuestions;
        if (options.session_host.len > 256) return error.InvalidSessionHost;
        const uri = std.Uri.parse(options.session_host) catch return error.InvalidSessionHost;
        const secure = if (std.mem.eql(u8, uri.scheme, "https")) true else if (std.mem.eql(u8, uri.scheme, "http")) false else return error.InvalidSessionHost;

        const self = try allocator.create(Authenticator);
        const region_bytes = regionBytes(options.questions);
        const region = try allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), region_bytes);
        const bits = try allocator.alloc(usize, BuddyAllocator.bitWords(region_bytes));
        self.* = .{
            .server_io = server_io,
            .wake = wake,
            .timeout = options.timeout,
            .questions = options.questions,
            .buddy = .init(region, bits),
            .threaded = undefined,
            .client = undefined,
            .slots = try allocator.alloc(Slot, connections),
            .pending = try allocator.alloc(u32, connections),
        };
        @memcpy(self.host_bytes[0..options.session_host.len], options.session_host);
        self.host_len = options.session_host.len;
        for (self.slots) |*slot| slot.* = .{};
        const memory = self.buddy.allocator();
        self.threaded = .init(memory, .{
            .async_limit = .nothing,
            .concurrent_limit = .limited(2 * @as(usize, options.questions)),
            .stack_size = options.stack_bytes,
        });
        const io = self.threaded.io();
        self.client = .{ .allocator = memory, .io = io };
        // Idle connections kept for the next questions, at most one each.
        self.client.connection_pool.free_size = options.questions;
        var certificate_used: usize = 0;
        if (secure) {
            const now = std.Io.Clock.real.now(io);
            certificate_used = loadCertificates(allocator, io, now, options.certificate_bytes, &self.client.ca_bundle) catch |err| {
                self.client.ca_bundle = .empty;
                self.client.deinit();
                self.threaded.deinit();
                return err;
            };
            // The bundle is current, so the client never reads the system's again.
            self.client.now = now;
        }
        std.log.info("event=authentication_ready questions={d} region_bytes={d} certificates={d} certificate_bytes={d} certificate_limit={d}", .{ options.questions, region_bytes, self.client.ca_bundle.map.count(), certificate_used, options.certificate_bytes });
        return self;
    }

    /// Ends the questions still out and gives back everything the client and I/O hold.
    pub fn close(self: *Authenticator) void {
        const io = self.threaded.io();
        self.tasks.cancel(io);
        // The certificates are plugin memory, not the client's to free.
        self.client.ca_bundle = .empty;
        self.client.deinit();
        self.threaded.deinit();
        if (!self.buddy.whole()) std.log.err("event=authentication_leak used_bytes={d}", .{self.buddy.used});
    }

    /// The system's root certificates, read once through scratch memory and kept in `limit`
    /// bytes of plugin memory, the bytes as read and the lookup map built at its final size.
    /// Returns the bytes kept.
    fn loadCertificates(allocator: std.mem.Allocator, io: std.Io, now: std.Io.Timestamp, limit: usize, bundle: *std.crypto.Certificate.Bundle) !usize {
        // Reading grows lists as it goes, peaking near ten times what it keeps: 1.2 MB for
        // 132 KiB. The scratch is the system's, and given back before the server starts.
        const scratch = try std.heap.page_allocator.alloc(u8, certificate_scratch_bytes);
        defer std.heap.page_allocator.free(scratch);
        var reading = std.heap.FixedBufferAllocator.init(scratch);
        var loaded: std.crypto.Certificate.Bundle = .empty;
        loaded.rescan(reading.allocator(), io, now) catch |err| return switch (err) {
            error.OutOfMemory => error.RootCertificatesTooLarge,
            else => err,
        };
        if (loaded.map.count() == 0) return error.NoRootCertificates;

        var kept = std.heap.FixedBufferAllocator.init(try allocator.alloc(u8, limit));
        const memory = kept.allocator();
        bundle.* = .{ .bytes = .fromOwnedSlice(memory.dupe(u8, loaded.bytes.items) catch return error.RootCertificatesTooLarge), .map = .empty };
        const context: CertificateMapContext = .{ .cb = bundle };
        bundle.map.ensureTotalCapacityContext(memory, loaded.map.count(), context) catch return error.RootCertificatesTooLarge;
        var entries = loaded.map.iterator();
        while (entries.next()) |entry| bundle.map.putAssumeCapacityContext(entry.key_ptr.*, entry.value_ptr.*, context);
        return kept.end_index;
    }

    /// The bundle keeps its map's context private; its insert names it.
    const CertificateMapContext = @typeInfo(@TypeOf(@FieldType(std.crypto.Certificate.Bundle, "map").putContext)).@"fn".param_types[4].?;
    const certificate_scratch_bytes = 4 * 1024 * 1024;

    /// Starts asking whether the player joined with this hash. The answer comes later, from
    /// `answer`, once the connection is woken.
    pub fn ask(self: *Authenticator, handle: sessions.Handle, name: []const u8, server_hash: [20]u8) !void {
        const slot = &self.slots[handle.index];
        // A connection gone before its answer came still holds the slot until it does.
        if (slot.state.load(.acquire) != .idle) return error.SlotBusy;
        if (name.len == 0 or name.len > slot.name.len) return error.InvalidName;
        @memcpy(slot.name[0..name.len], name);
        slot.name_len = @intCast(name.len);
        slot.server_id_len = @intCast(minecraftDigest(server_hash, &slot.server_id).len);
        slot.handle = handle;
        slot.state.store(.queued, .release);

        const index: u32 = @intCast(handle.index);
        {
            self.mutex.lockUncancelable(self.server_io);
            defer self.mutex.unlock(self.server_io);
            if (self.running == self.questions) {
                // Every slot is queued at most once, so the queue never fills.
                self.pending[(self.pending_head + self.pending_len) % self.pending.len] = index;
                self.pending_len += 1;
                return;
            }
            self.running += 1;
        }
        self.tasks.concurrent(self.threaded.io(), drain, .{ self, index }) catch |err| {
            self.mutex.lockUncancelable(self.server_io);
            self.running -= 1;
            self.mutex.unlock(self.server_io);
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

    fn host(self: *const Authenticator) []const u8 {
        return self.host_bytes[0..self.host_len];
    }

    /// Asks the question it was started for, then those waiting, until none are.
    fn drain(self: *Authenticator, first: u32) std.Io.Cancelable!void {
        const io = self.threaded.io();
        var index = first;
        while (true) {
            const slot = &self.slots[index];
            slot.answer = try self.question(slot);
            slot.state.store(.answered, .release);
            self.wake.connection(slot.handle);

            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.pending_len == 0) {
                self.running -= 1;
                return;
            }
            index = self.pending[self.pending_head];
            self.pending_head = (self.pending_head + 1) % self.pending.len;
            self.pending_len -= 1;
        }
    }

    /// One question, given until its deadline: the request runs as a task of its own, so this
    /// one can stop waiting on it.
    fn question(self: *Authenticator, slot: *const Slot) std.Io.Cancelable!Answer {
        const io = self.threaded.io();
        var finished: std.Io.Event = .unset;
        var asking = io.concurrent(fetch, .{ self, slot, &finished }) catch |err| {
            std.log.warn("event=authentication_unavailable connection={d}:{d} reason={t}", .{ slot.handle.index, slot.handle.generation, err });
            return .unavailable;
        };
        finished.waitTimeout(io, .{ .duration = .{ .raw = self.timeout, .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => {
                _ = asking.cancel(io) catch {};
                return error.Canceled;
            },
        };
        if (finished.isSet()) return asking.await(io) catch |err| {
            std.log.warn("event=authentication_unavailable connection={d}:{d} reason={t}", .{ slot.handle.index, slot.handle.generation, err });
            return .unavailable;
        };
        _ = asking.cancel(io) catch {};
        std.log.warn("event=authentication_unavailable connection={d}:{d} reason=Timeout", .{ slot.handle.index, slot.handle.generation });
        return .unavailable;
    }

    /// The request, which tells the question when it is done; the question reports how it went,
    /// knowing whether it gave up on it first.
    fn fetch(self: *Authenticator, slot: *const Slot, finished: *std.Io.Event) anyerror!Answer {
        defer finished.set(self.threaded.io());
        return self.request(slot);
    }

    fn request(self: *Authenticator, slot: *const Slot) !Answer {
        var url_bytes: [url_max]u8 = undefined;
        var url: std.Io.Writer = .fixed(&url_bytes);
        try url.print("{s}/session/minecraft/hasJoined?username=", .{self.host()});
        // Offline clients may send any name; escaping keeps it one query value.
        try std.Uri.Component.percentEncode(&url, slot.name[0..slot.name_len], isUnreserved);
        try url.print("&serverId={s}", .{slot.server_id[0..slot.server_id_len]});

        const uri = try std.Uri.parse(url.buffered());
        var asked = try self.client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{ .user_agent = .{ .override = "lightning-rod" } },
        });
        defer asked.deinit();
        try asked.sendBodiless();
        var redirect: [1024]u8 = undefined;
        var response = try asked.receiveHead(&redirect);
        switch (response.head.status) {
            .ok => {},
            .no_content => {
                // A 204 has no body, but std (0.17.0 and 0.17.1) reads one until the server
                // closes, in `fetch` and when the request ends, and Mojang keeps the connection
                // open (ziglang/zig#25181). Marking the response read ends the request at once
                // and keeps the connection for the next question.
                asked.reader.state = .ready;
                return .unverified;
            },
            else => return .unavailable,
        }
        // The default Accept-Encoding offers gzip and deflate, read through this window rather
        // than one the client allocates.
        switch (response.head.content_encoding) {
            .identity, .gzip, .deflate => {},
            else => return error.UnexpectedEncoding,
        }
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var transfer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer, &decompress, &window);
        var body_bytes: [response_max]u8 = undefined;
        var body: std.Io.Writer = .fixed(&body_bytes);
        _ = reader.streamRemaining(&body) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            error.WriteFailed => return error.AnswerTooLarge,
            else => |e| return e,
        };
        var scratch: [scratch_max]u8 = undefined;
        return parseJoined(body.buffered(), &scratch);
    }
};

/// A hasJoined answer: the profile, or `unavailable` for anything not shaped like one.
pub fn parseJoined(json: []const u8, scratch: []u8) Authenticator.Answer {
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
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

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
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
    var scratch: [Authenticator.scratch_max]u8 = undefined;
    const answer = parseJoined(json, &scratch);
    try std.testing.expect(answer == .joined);
    const profile = answer.joined;
    try std.testing.expectEqual(@as(u128, 0x069a79f444e94726a5befca90e38aaf5), profile.uuid);
    try std.testing.expectEqualStrings("Notch", profile.nameText());
    try std.testing.expectEqualStrings("eyJ0ZXh0dXJlcyI6e319", profile.textures_value[0..profile.textures_value_len]);
    try std.testing.expectEqualStrings("c2lnbmVk", profile.textures_signature[0..profile.textures_signature_len]);
    try std.testing.expect(parseJoined("{\"id\":\"short\",\"name\":\"x\"}", &scratch) == .unavailable);
    try std.testing.expect(parseJoined("not json", &scratch) == .unavailable);
}

/// Answers hasJoined as Mojang would: Notch joined, slow takes too long, anyone else did not.
/// Counts the connections it accepts, to show the client keeps its own.
const FakeSessionServer = struct {
    listener: std.Io.net.Server,
    group: std.Io.Group = .init,
    accepted: std.atomic.Value(usize) = .init(0),

    fn serve(self: *FakeSessionServer, io: std.Io) std.Io.Cancelable!void {
        while (true) {
            const stream = self.listener.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            _ = self.accepted.fetchAdd(1, .monotonic);
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
                // A 204 without a length, as Mojang answers it. Zig 0.17.0's client read such a
                // body until the server closed, which Mojang never does (ziglang/zig#25181).
                request.respond("", .{ .status = .no_content, .transfer_encoding = .none }) catch return;
            }
        }
    }
};

fn awaitAnswers(authenticator: *Authenticator, handles: []const sessions.Handle, answers: []?Authenticator.Answer) !void {
    var waited: usize = 0;
    while (true) : (waited += 1) {
        var missing = false;
        for (handles, answers) |handle, *slot| {
            if (slot.* == null) slot.* = authenticator.answer(handle);
            missing = missing or slot.* == null;
        }
        if (!missing) return;
        if (waited == 500) return error.NoAnswer;
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    }
}

test "asks a session server for more players than run at once" {
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
    const options: Options = .{
        .session_host = try std.fmt.bufPrint(&host, "http://127.0.0.1:{d}", .{fake.listener.socket.address.getPort()}),
        .questions = 2,
        .timeout = .fromMilliseconds(500),
    };
    const connections = 4;
    const memory = try std.testing.allocator.alloc(u8, Authenticator.memoryBytes(options, connections));
    defer std.testing.allocator.free(memory);
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    const wake: sessions.Wake = .{};
    const authenticator = try Authenticator.init(fixed.allocator(), io, options, connections, &wake);
    var closed = false;
    defer if (!closed) authenticator.close();

    const notch: sessions.Handle = .{ .index = 0, .generation = 1 };
    const nobody: sessions.Handle = .{ .index = 1, .generation = 1 };
    const slow: sessions.Handle = .{ .index = 2, .generation = 1 };
    const hash: [20]u8 = @splat(0xab);
    // Three questions, two at a time: one waits its turn.
    try authenticator.ask(slow, "slow", hash);
    try authenticator.ask(notch, "Notch", hash);
    try authenticator.ask(nobody, "nobody", hash);
    try std.testing.expectError(error.SlotBusy, authenticator.ask(notch, "Notch", hash));

    var answers: [3]?Authenticator.Answer = @splat(null);
    try awaitAnswers(authenticator, &.{ notch, nobody, slow }, &answers);
    const profile = answers[0].?.joined;
    try std.testing.expectEqual(@as(u128, 0x069a79f444e94726a5befca90e38aaf5), profile.uuid);
    try std.testing.expectEqualStrings("dGV4dHVyZXM=", profile.textures_value[0..profile.textures_value_len]);
    try std.testing.expect(answers[1].? == .unverified);
    // The question the server sat on ended at its deadline.
    try std.testing.expect(answers[2].? == .unavailable);
    // An answer is taken once, and the slot is free for the next question.
    try std.testing.expect(authenticator.answer(notch) == null);

    // A kept connection answers the next question without a new one.
    var accepted: usize = 0;
    for (2..4) |generation| {
        const again: sessions.Handle = .{ .index = 0, .generation = @intCast(generation) };
        try authenticator.ask(again, "Notch", hash);
        var more: [1]?Authenticator.Answer = @splat(null);
        try awaitAnswers(authenticator, &.{again}, &more);
        try std.testing.expect(more[0].? == .joined);
        if (generation == 3) try std.testing.expectEqual(accepted, fake.accepted.load(.monotonic));
        accepted = fake.accepted.load(.monotonic);
    }

    // Everything the client and its I/O took comes back to the region.
    closed = true;
    authenticator.close();
    try std.testing.expect(authenticator.buddy.whole());
}
