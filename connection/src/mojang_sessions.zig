//! Asks Mojang's session server whether players joined, without the sessions thread waiting.
//!
//! A fixed set of workers, started with the server, takes questions from a queue as deep as there
//! are connections. Each worker owns its buffers and keeps one connection to the session server
//! alive between questions. A watchdog ends a question past its deadline by shutting its socket
//! down. After startup nothing allocates and no thread starts; the only startup heap use is the
//! scratch the system's root certificates are read with, copied into plugin memory and freed.
const std = @import("std");
const sessions = @import("sessions");
const tls = std.crypto.tls;
const Bundle = std.crypto.Certificate.Bundle;

pub const Options = struct {
    /// Where hasJoined is asked: `https://host[:port]`, or `http://` for a local stand in.
    session_host: []const u8,
    /// Questions asked at once; the rest wait their turn in the queue.
    workers: u16 = 16,
    /// How long a question may take before the player is told the servers are down.
    timeout: std.Io.Duration = .fromSeconds(10),
    /// Room for the system's root certificates. A typical bundle takes about 140 KB.
    certificate_bytes: usize = 512 * 1024,
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

    const Worker = struct {
        stream: ?std.Io.net.Stream = null,
        /// How far the connection got, so a failure reads only what was set up.
        progress: enum { closed, connected, secured } = .closed,
        /// Awake-clock nanoseconds the current question must end by, zero between questions.
        deadline: i96 = 0,
        socket_reader: std.Io.net.Stream.Reader = undefined,
        socket_writer: std.Io.net.Stream.Writer = undefined,
        tls_client: tls.Client = undefined,
        http: std.http.Reader = undefined,
        socket_input: [tls.Client.min_buffer_len]u8 = undefined,
        socket_output: [tls.Client.min_buffer_len]u8 = undefined,
        tls_read: [tls.Client.min_buffer_len]u8 = undefined,
        tls_write: [tls.Client.min_buffer_len]u8 = undefined,
        transfer: [4096]u8 = undefined,
        body: [response_max]u8 = undefined,
        scratch: [scratch_max]u8 = undefined,

        fn input(self: *Worker, secure: bool) *std.Io.Reader {
            return if (secure) &self.tls_client.reader else &self.socket_reader.interface;
        }

        fn output(self: *Worker, secure: bool) *std.Io.Writer {
            return if (secure) &self.tls_client.writer else &self.socket_writer.interface;
        }
    };

    /// A hasJoined answer is about a kilobyte and a half; this leaves room for more properties.
    const response_max = 16 * 1024;
    /// What parsing an answer of `response_max` bytes may take.
    const scratch_max = 32 * 1024;
    const head_max = 8 * 1024;

    io: std.Io,
    wake: *const sessions.Wake,
    timeout: std.Io.Duration,
    secure: bool,
    host_bytes: [std.Io.net.HostName.max_len]u8 = undefined,
    host_len: usize = 0,
    port: u16,
    slots: []Slot,
    queue: std.Io.Queue(u32),
    workers: []Worker,
    group: std.Io.Group = .init,
    /// Guards worker sockets and deadlines between workers and the watchdog.
    mutex: std.Io.Mutex = .init,
    deadlines: std.Io.Condition = .init,
    certificates: Bundle = .empty,
    certificates_lock: std.Io.RwLock = .init,

    /// What `init` allocates, for the plugin to declare.
    pub fn memoryBytes(options: Options, connections: usize) usize {
        // Each allocation carries the plugin allocator's bookkeeping and alignment.
        const slack = 4 * 1024;
        return @sizeOf(Authenticator) + connections * (@sizeOf(Slot) + @sizeOf(u32)) + @as(usize, options.workers) * @sizeOf(Worker) + options.certificate_bytes + slack;
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options, connections: usize, wake: *const sessions.Wake) !*Authenticator {
        if (options.workers == 0) return error.NoAuthenticationWorkers;
        const uri = std.Uri.parse(options.session_host) catch return error.InvalidSessionHost;
        const secure = if (std.mem.eql(u8, uri.scheme, "https")) true else if (std.mem.eql(u8, uri.scheme, "http")) false else return error.InvalidSessionHost;
        const self = try allocator.create(Authenticator);
        const queued = try allocator.alloc(u32, connections);
        self.* = .{
            .io = io,
            .wake = wake,
            .timeout = options.timeout,
            .secure = secure,
            .port = uri.port orelse if (secure) 443 else 80,
            .slots = try allocator.alloc(Slot, connections),
            .queue = .init(queued),
            .workers = try allocator.alloc(Worker, options.workers),
        };
        // The name may be a slice of the URI rather than of the buffer, so it is copied in.
        var name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const name = (std.Io.net.HostName.fromUri(uri, &name_buffer) catch return error.InvalidSessionHost).bytes;
        @memcpy(self.host_bytes[0..name.len], name);
        self.host_len = name.len;
        for (self.slots) |*slot| slot.* = .{};
        for (self.workers) |*worker| worker.* = .{};
        if (secure) try self.loadCertificates(allocator, options.certificate_bytes);
        errdefer self.close();
        for (self.workers) |*worker| try self.group.concurrent(io, work, .{ self, worker });
        try self.group.concurrent(io, watch, .{self});
        return self;
    }

    /// Stops the workers, ending the questions still out.
    pub fn close(self: *Authenticator) void {
        // A worker waiting on a connect is not where cancelation reaches; shutting its socket is.
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.workers) |*worker| if (worker.stream) |stream| stream.shutdown(self.io, .both) catch {};
        }
        self.queue.close(self.io);
        self.group.cancel(self.io);
        for (self.workers) |*worker| self.disconnect(worker);
    }

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
        // The queue holds every connection, and a slot is queued once, so it never fills.
        if (try self.queue.put(self.io, &.{@as(u32, @intCast(handle.index))}, 0) != 1) unreachable;
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

    fn loadCertificates(self: *Authenticator, allocator: std.mem.Allocator, room: usize) !void {
        // Reading the bundle grows lists as it goes, peaking near ten times what it keeps.
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var loaded: Bundle = .empty;
        try loaded.rescan(scratch.allocator(), self.io, std.Io.Clock.real.now(self.io));
        if (loaded.map.count() == 0) return error.NoRootCertificates;
        const map_bytes = loaded.map.capacity() * (@sizeOf(std.crypto.Certificate.der.Element.Slice) + @sizeOf(u32) + 1);
        if (loaded.bytes.items.len + map_bytes > room) return error.RootCertificatesTooLarge;
        self.certificates.bytes = .fromOwnedSlice(try allocator.dupe(u8, loaded.bytes.items));
        const context: MapContext = .{ .cb = &self.certificates };
        try self.certificates.map.ensureTotalCapacityContext(allocator, loaded.map.count(), context);
        var entries = loaded.map.iterator();
        while (entries.next()) |entry| self.certificates.map.putAssumeCapacityContext(entry.key_ptr.*, entry.value_ptr.*, context);
    }

    /// The bundle keeps its map's context private; its insert names it.
    const MapContext = @typeInfo(@TypeOf(@FieldType(Bundle, "map").putContext)).@"fn".param_types[4].?;

    fn work(self: *Authenticator, worker: *Worker) std.Io.Cancelable!void {
        while (true) {
            const index = self.queue.getOne(self.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Closed => return,
            };
            const slot = &self.slots[index];
            slot.answer = self.question(worker, slot) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => failed: {
                    std.log.warn("event=authentication_unavailable connection={d}:{d} reason={t}", .{ slot.handle.index, slot.handle.generation, err });
                    break :failed .unavailable;
                },
            };
            slot.state.store(.answered, .release);
            self.wake.connection(slot.handle);
        }
    }

    /// What a failed read or write was, rather than that one failed.
    fn cause(self: *const Authenticator, worker: *const Worker, err: anyerror) anyerror {
        _ = self;
        if (err != error.ReadFailed and err != error.WriteFailed) return err;
        if (worker.progress == .closed) return err;
        if (worker.socket_reader.err) |found| return found;
        if (worker.socket_writer.err) |found| return found;
        if (worker.progress == .secured) if (worker.tls_client.read_err) |found| return found;
        return err;
    }

    fn question(self: *Authenticator, worker: *Worker, slot: *const Slot) !Answer {
        const deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + self.timeout.nanoseconds;
        self.arm(worker, deadline);
        defer self.arm(worker, 0);
        // A kept connection the server has since closed fails at once; one new one is tried.
        const reused = worker.stream != null;
        if (self.exchange(worker, slot)) |result| return result else |failure| {
            const err = self.cause(worker, failure);
            self.disconnect(worker);
            if (err == error.Canceled or !reused or std.Io.Clock.now(.awake, self.io).nanoseconds >= deadline) return err;
        }
        return self.exchange(worker, slot) catch |failure| {
            const err = self.cause(worker, failure);
            self.disconnect(worker);
            return err;
        };
    }

    fn exchange(self: *Authenticator, worker: *Worker, slot: *const Slot) !Answer {
        if (worker.stream == null) try self.connect(worker);
        const out = worker.output(self.secure);
        try out.writeAll("GET /session/minecraft/hasJoined?username=");
        // Offline clients may send any name; escaping keeps it one query value.
        try std.Uri.Component.percentEncode(out, slot.name[0..slot.name_len], isUnreserved);
        try out.print("&serverId={s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: lightning-rod\r\nAccept: application/json\r\nConnection: keep-alive\r\n\r\n", .{ slot.server_id[0..slot.server_id_len], self.host() });
        try out.flush();
        if (self.secure) try worker.socket_writer.interface.flush();

        worker.http = .{ .in = worker.input(self.secure), .interface = undefined, .state = .ready, .max_head_len = head_max };
        const head = try std.http.Client.Response.Head.parse(try worker.http.receiveHead());
        // Nothing asked for compression, so a compressed answer is not one.
        if (head.content_encoding != .identity) return error.UnexpectedEncoding;
        const status = head.status;
        const keep = head.keep_alive;
        // No content means no body, whatever the head leaves out.
        if (status == .no_content) {
            if (!keep) self.disconnect(worker);
            return .unverified;
        }
        const body = worker.http.bodyReader(&worker.transfer, head.transfer_encoding, head.content_length);
        var received: std.Io.Writer = .fixed(&worker.body);
        _ = body.streamRemaining(&received) catch |err| return if (err == error.WriteFailed) error.AnswerTooLarge else worker.http.body_err orelse err;
        if (!keep or worker.http.state != .ready) self.disconnect(worker);
        return switch (status) {
            .ok => parseJoined(received.buffered(), &worker.scratch),
            else => .unavailable,
        };
    }

    fn connect(self: *Authenticator, worker: *Worker) !void {
        // A local stand in is named by address; the session server by name.
        const stream = if (std.Io.net.IpAddress.parse(self.host(), self.port)) |address| try self.open(worker, address) else |_| connected: {
            const name = try std.Io.net.HostName.init(self.host());
            var results_buffer: [16]std.Io.net.HostName.LookupResult = undefined;
            var results: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&results_buffer);
            try name.lookup(self.io, &results, .{ .port = self.port });
            var failure: anyerror = error.UnknownHostName;
            break :connected while (results.getOneUncancelable(self.io)) |result| switch (result) {
                .address => |address| break self.open(worker, address) catch |err| {
                    failure = err;
                    continue;
                },
                .canonical_name => {},
            } else |err| switch (err) {
                error.Closed => return failure,
            };
        };
        worker.socket_reader = stream.reader(self.io, &worker.socket_input);
        worker.socket_writer = stream.writer(self.io, &worker.socket_output);
        worker.progress = .connected;
        if (!self.secure) return;
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        self.io.random(&entropy);
        worker.tls_client = try tls.Client.init(&worker.socket_reader.interface, &worker.socket_writer.interface, .{
            .host = .{ .explicit = self.host() },
            // Linux verifies against the bundle alone; the allocator is for fetching more roots.
            .ca = .{ .bundle = .{ .gpa = .failing, .io = self.io, .lock = &self.certificates_lock, .bundle = &self.certificates } },
            .read_buffer = &worker.tls_read,
            .write_buffer = &worker.tls_write,
            .entropy = &entropy,
            .realtime_now = std.Io.Clock.real.now(self.io),
        });
        worker.progress = .secured;
    }

    /// Connects to the address over a socket the watchdog sees from the start: std's connect
    /// takes no deadline yet, and shutting a socket down ends its pending connect on Linux.
    fn open(self: *Authenticator, worker: *Worker, address: std.Io.net.IpAddress) !std.Io.net.Stream {
        const linux = std.os.linux;
        const Storage = extern union { in: linux.sockaddr.in, in6: linux.sockaddr.in6 };
        var storage: Storage = undefined;
        const family: u32, const length: linux.socklen_t = switch (address) {
            .ip4 => |ip| family: {
                storage = .{ .in = .{ .port = std.mem.nativeToBig(u16, ip.port), .addr = @bitCast(ip.bytes) } };
                break :family .{ linux.AF.INET, @sizeOf(linux.sockaddr.in) };
            },
            .ip6 => |ip| family: {
                storage = .{ .in6 = .{ .port = std.mem.nativeToBig(u16, ip.port), .flowinfo = ip.flow, .addr = ip.bytes, .scope_id = ip.interface.index } };
                break :family .{ linux.AF.INET6, @sizeOf(linux.sockaddr.in6) };
            },
        };
        const opened = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
        if (linux.errno(opened) != .SUCCESS) return error.SystemResources;
        const stream: std.Io.net.Stream = .{ .socket = .{ .handle = @intCast(opened), .address = address } };
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            worker.stream = stream;
        }
        errdefer self.disconnect(worker);
        while (true) switch (linux.errno(linux.connect(stream.socket.handle, &storage, length))) {
            .SUCCESS => return stream,
            .INTR => continue,
            .CONNREFUSED => return error.ConnectionRefused,
            .TIMEDOUT => return error.Timeout,
            else => return error.ConnectFailed,
        };
    }

    fn disconnect(self: *Authenticator, worker: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const stream = worker.stream orelse return;
        stream.close(self.io);
        worker.stream = null;
        worker.progress = .closed;
    }

    fn arm(self: *Authenticator, worker: *Worker, deadline: i96) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        worker.deadline = deadline;
        if (deadline != 0) self.deadlines.signal(self.io);
    }

    /// Shuts down the socket of every question past its deadline, which ends the worker's wait on
    /// it. Sleeps until the earliest deadline, and without one until a question starts.
    fn watch(self: *Authenticator) std.Io.Cancelable!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            const now = std.Io.Clock.now(.awake, self.io).nanoseconds;
            var earliest: ?i96 = null;
            for (self.workers) |*worker| {
                if (worker.deadline == 0 or worker.deadline == tripped) continue;
                if (worker.deadline <= now) {
                    if (worker.stream) |stream| stream.shutdown(self.io, .both) catch {};
                    // Shut once; the worker clears its deadline as the question ends.
                    worker.deadline = tripped;
                    continue;
                }
                earliest = @min(earliest orelse worker.deadline, worker.deadline);
            }
            if (earliest) |deadline| {
                self.deadlines.waitTimeout(self.io, &self.mutex, .{ .deadline = .{ .raw = .{ .nanoseconds = deadline }, .clock = .awake } }) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.Timeout => {},
                };
            } else try self.deadlines.wait(self.io, &self.mutex);
        }
    }

    const tripped = std.math.maxInt(i96);
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
/// Counts the connections it accepts, to show workers keep theirs.
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
                request.respond("", .{ .status = .no_content }) catch return;
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

test "asks a session server for many players at once with fixed workers" {
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
    const options: Options = .{ .session_host = try std.fmt.bufPrint(&host, "http://127.0.0.1:{d}", .{fake.listener.socket.address.getPort()}), .workers = 2, .timeout = .fromMilliseconds(500) };
    const connections = 4;
    const memory = try std.testing.allocator.alloc(u8, Authenticator.memoryBytes(options, connections));
    defer std.testing.allocator.free(memory);
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    const wake: sessions.Wake = .{};
    const authenticator = try Authenticator.init(fixed.allocator(), io, options, connections, &wake);
    defer authenticator.close();

    const notch: sessions.Handle = .{ .index = 0, .generation = 1 };
    const nobody: sessions.Handle = .{ .index = 1, .generation = 1 };
    const slow: sessions.Handle = .{ .index = 2, .generation = 1 };
    const hash: [20]u8 = @splat(0xab);
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
    // The watchdog ended the question the server sat on.
    try std.testing.expect(answers[2].? == .unavailable);
    // An answer is taken once, and the slot is free for the next question.
    try std.testing.expect(authenticator.answer(notch) == null);

    // The worker that asked twice kept its connection; the one the watchdog cut reconnects.
    const accepted = fake.accepted.load(.monotonic);
    const again = [_]sessions.Handle{ .{ .index = 0, .generation = 2 }, .{ .index = 1, .generation = 2 } };
    try authenticator.ask(again[0], "Notch", hash);
    try authenticator.ask(again[1], "nobody", hash);
    var more: [2]?Authenticator.Answer = @splat(null);
    try awaitAnswers(authenticator, &again, &more);
    try std.testing.expect(more[0].? == .joined and more[1].? == .unverified);
    try std.testing.expect(fake.accepted.load(.monotonic) <= accepted + 1);
}

test "a session server that never accepts the connection is given up on in time" {
    const io = std.testing.io;
    // TEST-NET-1 is never routed, so the connect waits on a reply that does not come, unless
    // this machine has no route at all, which fails it at once.
    const options: Options = .{ .session_host = "http://192.0.2.1:80", .workers = 1, .timeout = .fromMilliseconds(300) };
    const memory = try std.testing.allocator.alloc(u8, Authenticator.memoryBytes(options, 1));
    defer std.testing.allocator.free(memory);
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    const wake: sessions.Wake = .{};
    const authenticator = try Authenticator.init(fixed.allocator(), io, options, 1, &wake);
    defer authenticator.close();

    const started = std.Io.Clock.now(.awake, io).nanoseconds;
    const handle: sessions.Handle = .{ .index = 0, .generation = 1 };
    try authenticator.ask(handle, "Notch", @splat(0));
    var answers: [1]?Authenticator.Answer = @splat(null);
    try awaitAnswers(authenticator, &.{handle}, &answers);
    try std.testing.expect(answers[0].? == .unavailable);
    try std.testing.expect(std.Io.Clock.now(.awake, io).nanoseconds - started < 3 * std.time.ns_per_s);
}
