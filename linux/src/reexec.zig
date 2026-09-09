const std = @import("std");
const contracts = @import("lightning_rod").runtime;
const executor = @import("reexec_executor.zig");
const handoff_fd = @import("reexec_handoff_fd.zig");
const reexec_manifest = @import("reexec_manifest.zig");
const reload = @import("reexec_reload.zig");
const restart_handoff = @import("restart_handoff.zig");

pub const Manifest = reexec_manifest;
pub const Handoff = restart_handoff;

pub const Error = error{
    DuplicateHandoff,
    InvalidHandoff,
};

const inherited_argument_limit = 1024;

pub fn SelfCandidate(comptime maximum_arguments: usize) type {
    if (maximum_arguments == 0) @compileError("re-exec candidate argument limit must be non-zero");
    if (maximum_arguments > inherited_argument_limit)
        @compileError("re-exec candidate arguments exceed inherited argv bound");
    return struct {
        const Self = @This();

        executable: [:0]const u8,
        arguments: []const [:0]const u8,
        expected: *const Manifest.Record,
        validated_fd: ?std.posix.fd_t = null,

        pub fn candidate(self: *Self) reload.Candidate {
            return .{ .context = self, .validate = validate, .release = release };
        }

        fn release(raw: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.validated_fd) |fd| _ = std.os.linux.close(fd);
            self.validated_fd = null;
        }

        fn validate(raw: *anyopaque) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            release(raw);
            if (self.executable.len == 0 or self.arguments.len == 0 or self.arguments.len > maximum_arguments)
                return .failed;
            if (!std.mem.eql(u8, self.executable, self.arguments[0])) return .failed;

            var inherited_count: usize = 0;
            for (self.arguments) |argument| {
                if (!std.mem.startsWith(u8, argument, handoff_fd.HandoffFd.argument_prefix)) continue;
                _ = handoff_fd.HandoffFd.fromArgument(argument) catch return .failed;
                inherited_count += 1;
                if (inherited_count > 1) return .failed;
            }
            self.validated_fd = openCandidate(self.executable, self.expected.*);
            return if (self.validated_fd != null) .ok else .failed;
        }
    };
}

const candidate_file_bytes = 64 * 1024 * 1024;
const candidate_section_limit = 4096;
const candidate_read_attempt_limit = 2048;
const elf_header_bytes = 64;
const elf_section_header_bytes = 64;

fn openCandidate(path: [:0]const u8, expected: Manifest.Record) ?std.posix.fd_t {
    const linux = std.os.linux;
    const opened = linux.openat(linux.AT.FDCWD, path.ptr, .{ .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: std.posix.fd_t = @intCast(opened);
    errdefer _ = linux.close(fd);

    var header: [elf_header_bytes]u8 = undefined;
    if (!preadExact(fd, &header, 0) or !validElfHeader(&header, expected.elf_machine)) return null;
    const section_offset = readU64(header[40..48]);
    const section_size = readU16(header[58..60]);
    const section_count = readU16(header[60..62]);
    const names_index = readU16(header[62..64]);
    if (section_size != elf_section_header_bytes or section_count == 0 or section_count > candidate_section_limit or names_index >= section_count)
        return null;
    if (!rangeValid(section_offset, @as(u64, section_count) * elf_section_header_bytes)) return null;

    var names_header: [elf_section_header_bytes]u8 = undefined;
    const names_offset = section_offset + @as(u64, names_index) * elf_section_header_bytes;
    if (!preadExact(fd, &names_header, names_offset)) return null;
    const names_data_offset = readU64(names_header[24..32]);
    const names_data_size = readU64(names_header[32..40]);
    if (!rangeValid(names_data_offset, names_data_size)) return null;

    var matches: usize = 0;
    for (0..section_count) |index| {
        var section: [elf_section_header_bytes]u8 = undefined;
        const offset = section_offset + @as(u64, @intCast(index)) * elf_section_header_bytes;
        if (!preadExact(fd, &section, offset)) return null;
        const name = readU32(section[0..4]);
        if (!sectionNameEquals(fd, names_data_offset, names_data_size, name, Manifest.section_name)) continue;
        if (readU32(section[4..8]) != 1) return null;
        const data_offset = readU64(section[24..32]);
        const data_size = readU64(section[32..40]);
        if (data_size != @sizeOf(Manifest.Record) or !rangeValid(data_offset, data_size)) return null;
        var candidate: Manifest.Record = undefined;
        if (!preadExact(fd, std.mem.asBytes(&candidate), data_offset)) return null;
        if (!compatibleManifest(expected, candidate)) return null;
        matches += 1;
    }
    if (matches != 1) return null;
    return fd;
}

fn compatibleManifest(predecessor: Manifest.Record, candidate: Manifest.Record) bool {
    if (!std.mem.eql(u8, &predecessor.magic_bytes, &candidate.magic_bytes) or
        predecessor.format != candidate.format or
        predecessor.envelope != candidate.envelope or
        predecessor.elf_machine != candidate.elf_machine or
        predecessor.session_id != candidate.session_id or
        predecessor.session_version != candidate.session_version or
        predecessor.protocol_count > Manifest.maximum_protocols or
        candidate.connection_capacity < predecessor.connection_capacity or
        candidate.continuation_capacity < predecessor.continuation_capacity or
        candidate.handoff_capacity < predecessor.handoff_capacity or
        candidate.protocol_count > Manifest.maximum_protocols) return false;
    for (predecessor.protocols[0..@as(usize, predecessor.protocol_count)]) |protocol| {
        var found = false;
        for (candidate.protocols[0..@as(usize, candidate.protocol_count)]) |supported|
            found = found or supported == protocol;
        if (!found) return false;
    }
    return true;
}

fn validElfHeader(bytes: []const u8, expected_machine: u16) bool {
    if (bytes.len < 20) return false;
    if (!std.mem.eql(u8, bytes[0..4], "\x7fELF")) return false;
    if (bytes[4] != 2 or bytes[5] != 1 or bytes[6] != 1) return false;
    const machine = @as(u16, bytes[18]) | (@as(u16, bytes[19]) << 8);
    return machine == expected_machine;
}

fn preadExact(fd: std.posix.fd_t, destination: []u8, offset: u64) bool {
    const linux = std.os.linux;
    var cursor: usize = 0;
    for (0..candidate_read_attempt_limit) |_| {
        if (cursor == destination.len) return true;
        const position = offset + @as(u64, @intCast(cursor));
        const result = linux.pread(fd, destination[cursor..].ptr, destination.len - cursor, @intCast(position));
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return false;
                cursor += @intCast(result);
            },
            .INTR => {},
            else => return false,
        }
    }
    return false;
}

fn sectionNameEquals(fd: std.posix.fd_t, strings_offset: u64, strings_size: u64, name_offset: u32, expected: []const u8) bool {
    const name_position: u64 = name_offset;
    const required: u64 = @intCast(expected.len + 1);
    if (name_position >= strings_size or required > strings_size - name_position) return false;
    var name: [64]u8 = undefined;
    if (expected.len + 1 > name.len) return false;
    if (!preadExact(fd, name[0 .. expected.len + 1], strings_offset + name_position)) return false;
    return name[expected.len] == 0 and std.mem.eql(u8, name[0..expected.len], expected);
}

fn rangeValid(offset: u64, length: u64) bool {
    return offset <= candidate_file_bytes and length <= candidate_file_bytes - offset;
}

fn readU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn readU64(bytes: []const u8) u64 {
    return @as(u64, bytes[0]) | (@as(u64, bytes[1]) << 8) | (@as(u64, bytes[2]) << 16) | (@as(u64, bytes[3]) << 24) |
        (@as(u64, bytes[4]) << 32) | (@as(u64, bytes[5]) << 40) | (@as(u64, bytes[6]) << 48) | (@as(u64, bytes[7]) << 56);
}

pub const Resume = struct {
    handoff: handoff_fd.HandoffFd,
    bytes: []const u8,
    listener: std.posix.fd_t,

    pub fn close(self: *Resume) void {
        self.handoff.close();
        self.* = undefined;
    }
};

pub fn inherited(arguments: []const [:0]const u8, storage: []u8) Error!?Resume {
    if (arguments.len > inherited_argument_limit) return error.InvalidHandoff;
    var found: ?handoff_fd.HandoffFd = null;
    for (arguments) |argument| {
        if (!std.mem.startsWith(u8, argument, handoff_fd.HandoffFd.argument_prefix)) continue;
        if (found != null) return error.DuplicateHandoff;
        found = handoff_fd.HandoffFd.fromArgument(argument) catch return error.InvalidHandoff;
    }
    const handoff = found orelse return null;
    errdefer handoff.close();
    if (!handoff.sealed()) return error.InvalidHandoff;
    const bytes = handoff.readInto(storage) catch return error.InvalidHandoff;
    var decoder = Handoff.Decoder.init(bytes) catch return error.InvalidHandoff;
    const listener = decoder.listenerFd();
    const count = decoder.remaining;
    for (0..count) |_| {
        _ = (decoder.next() catch return error.InvalidHandoff) orelse return error.InvalidHandoff;
    }
    if ((decoder.next() catch return error.InvalidHandoff) != null) return error.InvalidHandoff;
    return .{ .handoff = handoff, .bytes = bytes, .listener = listener };
}

test "candidate requires a checked executable manifest" {
    const record = Manifest.make(&.{771}, 1, 1, 1, 64, 1024);
    var policy = SelfCandidate(2){
        .executable = "server",
        .arguments = &.{ "server", "--lightning-rod-reexec-fd=17" },
        .expected = &record,
    };
    const candidate = policy.candidate();
    try std.testing.expectEqual(contracts.Outcome.failed, candidate.validate(candidate.context));
}

test "self candidate rejects a mismatched executable or duplicate handoff" {
    const record = Manifest.make(&.{771}, 1, 1, 1, 64, 1024);
    var mismatched = SelfCandidate(2){ .executable = "server", .arguments = &.{"other"}, .expected = &record };
    const first = mismatched.candidate();
    try std.testing.expectEqual(contracts.Outcome.failed, first.validate(first.context));

    var duplicated = SelfCandidate(2){
        .executable = "server",
        .arguments = &.{ "server", "--lightning-rod-reexec-fd=17", "--lightning-rod-reexec-fd=18" },
        .expected = &record,
    };
    const second = duplicated.candidate();
    try std.testing.expectEqual(contracts.Outcome.failed, second.validate(second.context));

    var over_limit = SelfCandidate(1){ .executable = "server", .arguments = &.{ "server", "--tui" }, .expected = &record };
    const third = over_limit.candidate();
    try std.testing.expectEqual(contracts.Outcome.failed, third.validate(third.context));
}

test "candidate manifest accepts only monotonic capacity and protocol changes" {
    const predecessor = Manifest.make(&.{771}, 9, 2, 64, 128, 512);
    const expanded = Manifest.make(&.{ 771, 772 }, 9, 2, 80, 256, 1024);
    const missing_protocol = Manifest.make(&.{772}, 9, 2, 80, 256, 1024);
    const reduced_capacity = Manifest.make(&.{771}, 9, 2, 63, 128, 512);
    const reduced_handoff = Manifest.make(&.{771}, 9, 2, 80, 256, 511);
    try std.testing.expect(compatibleManifest(predecessor, expanded));
    try std.testing.expect(!compatibleManifest(predecessor, missing_protocol));
    try std.testing.expect(!compatibleManifest(predecessor, reduced_capacity));
    try std.testing.expect(!compatibleManifest(predecessor, reduced_handoff));
}

pub fn Production(
    comptime TransportType: type,
    comptime SessionTableType: type,
    comptime maximum_arguments: usize,
) type {
    const Execve = executor.Execve(maximum_arguments);
    const TableSessions = reload.TableSessions(SessionTableType);
    return struct {
        const Self = @This();

        transport: *TransportType = undefined,
        executor: Execve = undefined,
        sessions: TableSessions = undefined,
        reloader: reload.Reloader = undefined,

        pub const Configuration = struct {
            transport: *TransportType,
            sessions: *SessionTableType,
            core: contracts.Core,
            candidate: reload.Candidate,
            candidate_fd: *?std.posix.fd_t,
            arguments: []const [:0]const u8,
            environment: [:null]const ?[*:0]const u8,
            image: []u8,
            continuation: []u8,
        };

        pub fn init(self: *Self, configuration: Configuration) void {
            self.transport = configuration.transport;
            self.executor = .{
                .arguments = configuration.arguments,
                .environment = configuration.environment,
                .candidate_fd = configuration.candidate_fd,
            };
            self.sessions = .{
                .table = configuration.sessions,
                .transport = configuration.transport.transport(),
            };
            self.reloader = .{
                .candidate = configuration.candidate,
                .core = configuration.core,
                .sessions = self.sessions.sessions(),
                .transport = configuration.transport.reloaderTransport(),
                .executor = self.executor.executor(),
                .image = configuration.image,
                .continuation = configuration.continuation,
            };
        }

        pub fn operation(self: *Self) contracts.Reloader {
            return self.reloader.operation();
        }

        pub fn restore(self: *Self, image: *Resume) Error!void {
            defer image.close();
            self.reloader.restoreConnections(image.bytes) catch return error.InvalidHandoff;
            self.transport.beginRestored() catch return error.InvalidHandoff;
        }
    };
}

pub fn ProductionWorker(comptime WorkerType: type, comptime maximum_arguments: usize) type {
    const Execve = executor.Execve(maximum_arguments);
    return struct {
        const Self = @This();

        worker: *WorkerType = undefined,
        executor: Execve = undefined,
        reloader: reload.Reloader = undefined,

        pub const Configuration = struct {
            worker: *WorkerType,
            core: contracts.Core,
            candidate: reload.Candidate,
            candidate_fd: *?std.posix.fd_t,
            arguments: []const [:0]const u8,
            environment: [:null]const ?[*:0]const u8,
            image: []u8,
            continuation: []u8,
        };

        pub fn init(self: *Self, configuration: Configuration) void {
            self.worker = configuration.worker;
            self.executor = .{
                .arguments = configuration.arguments,
                .environment = configuration.environment,
                .candidate_fd = configuration.candidate_fd,
            };
            self.reloader = .{
                .candidate = configuration.candidate,
                .core = configuration.core,
                .sessions = self.worker.reloaderSessions(),
                .transport = self.worker.reloaderTransport(),
                .executor = self.executor.executor(),
                .image = configuration.image,
                .continuation = configuration.continuation,
            };
        }

        pub fn operation(self: *Self) contracts.Reloader {
            return self.reloader.operation();
        }

        pub fn restore(self: *Self, image: *Resume) Error!void {
            defer image.close();
            self.reloader.restoreConnections(image.bytes) catch return error.InvalidHandoff;
            self.worker.transport.beginRestored() catch return error.InvalidHandoff;
        }
    };
}
