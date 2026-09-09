const std = @import("std");
const lightning_rod = @import("lightning_rod");
const exchange = lightning_rod.transport;
const runtime = lightning_rod.runtime;
const session = lightning_rod.session_api;
const crypto = lightning_rod.crypto_support;

pub const Offline = struct {
    io: *std.Io,

    pub fn init(io: *std.Io) Offline {
        return .{ .io = io };
    }

    pub fn interface(self: *Offline) session.Authentication {
        return .{
            .io = self.io,
            .max_pending = 0,
            .context = self,
            .vtable = &vtable,
        };
    }

    fn start(_: *anyopaque, request: session.Authentication.LoginStart) session.Authentication.Result {
        return .{ .accepted = .{ .uuid = uuid(request.username) } };
    }

    fn respond(_: *anyopaque, _: session.Authentication.EncryptionResponse) session.Authentication.Result {
        return .rejected;
    }

    fn poll(_: *anyopaque, _: exchange.Connection) session.Authentication.Result {
        return .rejected;
    }

    fn cancel(_: *anyopaque, _: exchange.Connection) void {}

    const vtable: session.Authentication.VTable = .{
        .start = start,
        .respond = respond,
        .poll = poll,
        .cancel = cancel,
    };

    pub fn uuid(username: []const u8) u128 {
        var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
        var hasher = std.crypto.hash.Md5.init(.{});
        hasher.update("OfflinePlayer:");
        hasher.update(username);
        hasher.final(&digest);
        digest[6] = (digest[6] & 0x0f) | 0x30;
        digest[8] = (digest[8] & 0x3f) | 0x80;
        return @bitCast(digest);
    }
};

pub fn Online(comptime maximum_pending: usize) type {
    return struct {
        const Self = @This();
        const token_bytes = 4;
        const Slot = struct {
            connection: exchange.Connection = .{ .index = 0, .generation = 0 },
            token: [token_bytes]u8 = @splat(0),
            username: [16]u8 = @splat(0),
            username_len: u8 = 0,
            secret: [16]u8 = @splat(0),
            active: bool = false,
        };

        pub const Verifier = struct {
            context: *anyopaque,
            vtable: *const VTable,
            readiness: ?runtime.Readiness = null,
            pub const Request = struct {
                connection: exchange.Connection,
                username: []const u8,
                server_hash: []const u8,
            };
            pub const Result = union(enum) { pending, accepted: u128, rejected };
            pub const VTable = struct {
                start: *const fn (*anyopaque, Request) Result,
                poll: *const fn (*anyopaque, exchange.Connection) Result,
                cancel: *const fn (*anyopaque, exchange.Connection) void,
            };
        };

        io: *std.Io,
        identity: crypto.Identity,
        verifier: Verifier,
        authenticate_client: bool = true,
        slots: [maximum_pending]Slot = @splat(.{}),

        pub fn init(io: *std.Io, verifier: Verifier, identity: crypto.Identity) Self {
            return .{ .io = io, .identity = identity, .verifier = verifier };
        }

        pub fn deinit(self: *Self) void {
            self.identity.deinit();
            @memset(&self.slots, .{});
        }

        pub fn interface(self: *Self) session.Authentication {
            return .{
                .io = self.io,
                .max_pending = maximum_pending,
                .context = self,
                .vtable = &vtable,
                .readiness = self.verifier.readiness,
            };
        }

        fn from(raw: *anyopaque) *Self {
            return @ptrCast(@alignCast(raw));
        }

        fn start(raw: *anyopaque, request: session.Authentication.LoginStart) session.Authentication.Result {
            const self = from(raw);
            if (request.username.len == 0 or request.username.len > 16) return .rejected;
            const slot = self.freeSlot() orelse return .rejected;
            slot.* = .{ .connection = request.connection, .username_len = @intCast(request.username.len), .active = true };
            @memcpy(slot.username[0..request.username.len], request.username);
            self.io.randomSecure(&slot.token) catch return self.reject(slot);
            return .{ .encryption_request = .{ .public_key = self.identity.publicKey(), .verify_token = &slot.token, .authenticate = self.authenticate_client } };
        }

        fn respond(raw: *anyopaque, request: session.Authentication.EncryptionResponse) session.Authentication.Result {
            const self = from(raw);
            const slot = self.find(request.connection) orelse return .rejected;
            var secret: [16]u8 = undefined;
            const decrypted_secret = self.identity.decrypt(&secret, request.shared_secret) catch return self.reject(slot);
            if (decrypted_secret.len != secret.len) return self.reject(slot);
            var token: [token_bytes]u8 = undefined;
            const decrypted_token = self.identity.decrypt(&token, request.verify_token) catch return self.reject(slot);
            if (!std.mem.eql(u8, decrypted_token, &slot.token)) return self.reject(slot);
            slot.secret = secret;
            var hash: [41]u8 = undefined;
            const server_hash = crypto.serverHash(secret, self.identity.publicKey(), &hash) orelse return self.reject(slot);
            return switch (self.verifier.vtable.start(self.verifier.context, .{ .connection = request.connection, .username = slot.username[0..slot.username_len], .server_hash = server_hash })) {
                .pending => .pending,
                .accepted => |uuid| self.accept(slot, uuid),
                .rejected => self.reject(slot),
            };
        }

        fn poll(raw: *anyopaque, handle: exchange.Connection) session.Authentication.Result {
            const self = from(raw);
            const slot = self.find(handle) orelse return .rejected;
            return switch (self.verifier.vtable.poll(self.verifier.context, handle)) {
                .pending => .pending,
                .accepted => |uuid| self.accept(slot, uuid),
                .rejected => self.reject(slot),
            };
        }

        fn cancel(raw: *anyopaque, handle: exchange.Connection) void {
            const self = from(raw);
            const slot = self.find(handle) orelse return;
            self.verifier.vtable.cancel(self.verifier.context, handle);
            std.crypto.secureZero(u8, &slot.secret);
            slot.* = .{};
        }

        fn freeSlot(self: *Self) ?*Slot {
            for (&self.slots) |*slot| if (!slot.active) return slot;
            return null;
        }
        fn find(self: *Self, handle: exchange.Connection) ?*Slot {
            for (&self.slots) |*slot| if (slot.active and slot.connection.eql(handle)) return slot;
            return null;
        }
        fn accept(self: *Self, slot: *Slot, uuid: u128) session.Authentication.Result {
            _ = self;
            const secret = slot.secret;
            std.crypto.secureZero(u8, &slot.secret);
            slot.* = .{};
            return .{ .accepted = .{ .uuid = uuid, .secret = secret } };
        }
        fn reject(self: *Self, slot: *Slot) session.Authentication.Result {
            _ = self;
            std.crypto.secureZero(u8, &slot.secret);
            slot.* = .{};
            return .rejected;
        }
        const vtable: session.Authentication.VTable = .{ .start = start, .respond = respond, .poll = poll, .cancel = cancel };
    };
}

pub fn HttpVerifier(comptime maximum_pending: usize) type {
    return struct {
        const Self = @This();
        const State = enum(u8) { free, pending, accepted, rejected };
        const Task = std.Io.Future(std.Io.Cancelable!void);
        const Slot = struct {
            connection: exchange.Connection = .{ .index = 0, .generation = 0 },
            state: std.atomic.Value(State) = .init(.free),
            uuid: u128 = 0,
            url: [256]u8 = undefined,
            url_len: u16 = 0,
            body: [512]u8 = undefined,
            body_len: u16 = 0,
            task: ?Task = null,
            finished: std.atomic.Value(bool) = .init(false),
            abandoned: std.atomic.Value(bool) = .init(false),
        };

        io: std.Io,
        client: std.http.Client,
        slots: [maximum_pending]Slot = @splat(.{}),
        wake: ?runtime.Wake = null,

        pub fn init(bounded_allocator: std.mem.Allocator, io: std.Io) Self {
            return .{ .io = io, .client = .{ .allocator = bounded_allocator, .io = io } };
        }

        pub fn deinit(self: *Self) void {
            for (&self.slots) |*slot| cancelSlot(self, slot);
            self.client.deinit();
        }

        pub fn interface(self: *Self) Online(maximum_pending).Verifier {
            return .{
                .context = self,
                .vtable = &vtable,
                .readiness = .{ .context = self, .bind_fn = bindReadiness },
            };
        }

        fn from(raw: *anyopaque) *Self {
            return @ptrCast(@alignCast(raw));
        }

        fn start(raw: *anyopaque, request: Online(maximum_pending).Verifier.Request) Online(maximum_pending).Verifier.Result {
            const self = from(raw);
            const slot = freeSlot(self) orelse return .rejected;
            const url = buildUrl(&slot.url, request.username, request.server_hash) orelse return .rejected;
            slot.connection = request.connection;
            slot.url_len = @intCast(url.len);
            slot.state.store(.pending, .release);
            slot.task = std.Io.concurrent(self.io, worker, .{ self, slot }) catch {
                slot.state.store(.free, .release);
                return .rejected;
            };
            return .pending;
        }

        fn poll(raw: *anyopaque, handle: exchange.Connection) Online(maximum_pending).Verifier.Result {
            const self = from(raw);
            const slot = findSlot(self, handle) orelse return .rejected;
            return switch (slot.state.load(.acquire)) {
                .pending => .pending,
                .accepted => {
                    const uuid = slot.uuid;
                    finishSlot(self, slot);
                    return .{ .accepted = uuid };
                },
                .rejected, .free => {
                    finishSlot(self, slot);
                    return .rejected;
                },
            };
        }

        fn cancel(raw: *anyopaque, handle: exchange.Connection) void {
            const self = from(raw);
            const slot = findSlot(self, handle) orelse return;
            slot.abandoned.store(true, .release);
        }

        fn worker(self: *Self, slot: *Slot) std.Io.Cancelable!void {
            defer {
                slot.finished.store(true, .release);
                self.signalReady();
            }
            var writer: std.Io.Writer = .fixed(&slot.body);
            const response = self.client.fetch(.{
                .location = .{ .url = slot.url[0..slot.url_len] },
                .response_writer = &writer,
                .redirect_buffer = &.{},
                .decompress_buffer = &.{},
            }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    slot.state.store(.rejected, .release);
                    return;
                },
            };
            slot.body_len = @intCast(writer.end);
            slot.uuid = if (response.status == .ok) parseUuid(slot.body[0..writer.end]) orelse 0 else 0;
            slot.state.store(if (slot.uuid == 0) .rejected else .accepted, .release);
        }

        fn bindReadiness(raw: *anyopaque, wake: runtime.Wake) runtime.Outcome {
            const self = from(raw);
            if (self.wake != null) return .failed;
            self.wake = wake;
            return .ok;
        }

        fn signalReady(self: *Self) void {
            if (self.wake) |wake| wake.signal();
        }

        fn freeSlot(self: *Self) ?*Slot {
            self.reapAbandoned();
            for (&self.slots) |*slot| if (slot.state.load(.acquire) == .free) return slot;
            return null;
        }

        fn reapAbandoned(self: *Self) void {
            for (&self.slots) |*slot| {
                if (!slot.abandoned.load(.acquire) or
                    !slot.finished.load(.acquire)) continue;
                finishSlot(self, slot);
            }
        }
        fn findSlot(self: *Self, handle: exchange.Connection) ?*Slot {
            for (&self.slots) |*slot| if (slot.state.load(.acquire) != .free and slot.connection.eql(handle)) return slot;
            return null;
        }
        fn finishSlot(self: *Self, slot: *Slot) void {
            if (slot.task) |*task| _ = task.await(self.io);
            slot.* = .{};
        }
        fn cancelSlot(self: *Self, slot: *Slot) void {
            if (slot.task) |*task| _ = task.cancel(self.io);
            slot.* = .{};
        }
        const vtable: Online(maximum_pending).Verifier.VTable = .{ .start = start, .poll = poll, .cancel = cancel };
    };
}

fn buildUrl(output: []u8, username: []const u8, server_hash: []const u8) ?[]const u8 {
    const prefix = "https://sessionserver.mojang.com/session/minecraft/hasJoined?username=";
    const middle = "&serverId=";
    if (prefix.len + username.len + middle.len + server_hash.len > output.len) return null;
    for (username) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return null;
    @memcpy(output[0..prefix.len], prefix);
    @memcpy(output[prefix.len..][0..username.len], username);
    @memcpy(output[prefix.len + username.len ..][0..middle.len], middle);
    @memcpy(output[prefix.len + username.len + middle.len ..][0..server_hash.len], server_hash);
    return output[0 .. prefix.len + username.len + middle.len + server_hash.len];
}

fn parseUuid(body: []const u8) ?u128 {
    const marker = "\"id\":\"";
    const start = std.mem.indexOf(u8, body, marker) orelse return null;
    const digits = body[start + marker.len ..];
    if (digits.len < 32) return null;
    var bytes: [16]u8 = undefined;
    for (0..16) |index| {
        const high = std.fmt.charToDigit(digits[index * 2], 16) catch return null;
        const low = std.fmt.charToDigit(digits[index * 2 + 1], 16) catch return null;
        bytes[index] = @intCast(high * 16 + low);
    }
    return std.mem.readInt(u128, &bytes, .big);
}

test "offline authentication is immediate and deterministic" {
    var io = std.Io.Threaded.global_single_threaded.io();
    var item = Offline.init(&io);
    const authentication = item.interface();
    const result = authentication.vtable.start(authentication.context, .{
        .connection = .{ .index = 0, .generation = 1 },
        .username = "Notch",
        .deadline_ns = 0,
    });
    const value = switch (result) {
        .accepted => |accepted| accepted.uuid,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(Offline.uuid("Notch"), value);
    try std.testing.expect(Offline.uuid("Notch") != Offline.uuid("Alex"));
}

test "online authentication issues a bounded challenge and rejects invalid RSA response" {
    const Verifier = Online(1).Verifier;
    const Stub = struct {
        fn start(_: *anyopaque, _: Verifier.Request) Verifier.Result {
            return .pending;
        }
        fn poll(_: *anyopaque, _: exchange.Connection) Verifier.Result {
            return .pending;
        }
        fn cancel(_: *anyopaque, _: exchange.Connection) void {}
    };
    var io = std.Io.Threaded.global_single_threaded.io();
    var context: u8 = 0;
    var online = Online(1).init(&io, .{ .context = &context, .vtable = &.{ .start = Stub.start, .poll = Stub.poll, .cancel = Stub.cancel } }, crypto.testing.identity());
    defer online.deinit();
    const auth = online.interface();
    const handle: exchange.Connection = .{ .index = 1, .generation = 2 };
    const challenge = switch (auth.vtable.start(auth.context, .{ .connection = handle, .username = "Alex", .deadline_ns = 1 })) {
        .encryption_request => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 162), challenge.public_key.len);
    try std.testing.expectEqual(@as(usize, 4), challenge.verify_token.len);
    try std.testing.expect(challenge.authenticate);
    const rejected = auth.vtable.respond(auth.context, .{
        .connection = handle,
        .username = "Alex",
        .shared_secret = "not-rsa",
        .verify_token = "not-rsa",
        .deadline_ns = 1,
    });
    try std.testing.expect(rejected == .rejected);
}

test "hasJoined URL and response UUID parsing are bounded" {
    var url: [256]u8 = undefined;
    const actual = buildUrl(&url, "Notch", "-1a2b").?;
    try std.testing.expectEqualStrings("https://sessionserver.mojang.com/session/minecraft/hasJoined?username=Notch&serverId=-1a2b", actual);
    try std.testing.expectEqual(@as(u128, 0x00112233445566778899aabbccddeeff), parseUuid("{\"id\":\"00112233445566778899aabbccddeeff\"}"));
    try std.testing.expect(parseUuid("{}") == null);
}
