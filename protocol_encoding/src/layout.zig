const std = @import("std");

/// Named output boundaries are checked separately by their concrete encoders.
pub const Node = struct {
    name: []const u8,
    destination: bool = false,
    shape: [32]u8,
    fingerprint: ?[32]u8 = null,
    children: []const u32,
    choice: ?struct { shape: [32]u8, branches: []const Branch } = null,
};

pub const Branch = struct { name: []const u8, node: u32 };
pub const Case = struct { choice: u32, field: []const u8, name: []const u8 };
pub const Tag = struct { key: u64, value: i128 };

/// Stable across compiler versions. Registration rejects duplicate identifiers.
pub fn nameKey(comptime name: []const u8) u64 {
    return comptime identifier: {
        @setEvalBranchQuota(10_000);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
        break :identifier std.mem.readInt(u64, digest[0..8], .little);
    };
}

pub fn candidates(comptime callbacks: anytype) if (@typeInfo(@TypeOf(callbacks)) == .@"struct") @TypeOf(callbacks) else std.meta.Tuple(&.{@TypeOf(callbacks)}) {
    return if (@typeInfo(@TypeOf(callbacks)) == .@"struct") callbacks else .{callbacks};
}

pub fn callbackCursor(comptime callback: anytype) type {
    const function = @typeInfo(@TypeOf(callback)).@"fn";
    return function.params[0].type orelse @compileError("nested writer must take a concrete cursor as its first argument");
}

pub fn sameCase(a: ?Case, b: ?Case) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?.field, b.?.field) and std.mem.eql(u8, a.?.name, b.?.name);
}

pub fn selectCase(comptime callbacks: anytype, protocol: i32, comptime selected_case: ?Case) ?usize {
    var result: ?usize = null;
    var latest: i32 = std.math.minInt(i32);
    inline for (candidates(callbacks), 0..) |callback, index| {
        const Source = callbackCursor(callback);
        if (comptime !sameCase(Source.restricted_case, selected_case)) continue;
        if (Source.protocol_number <= protocol and Source.protocol_number > latest) {
            result = index;
            latest = Source.protocol_number;
        }
    }
    return result;
}

pub fn requireCompatible(comptime Source: type, comptime Actual: type) void {
    @setEvalBranchQuota(1_000_000);
    check(Source, Actual.schema_nodes, Actual.schema_id, Actual.protocol_number);
}

fn check(comptime Source: type, comptime actual: []const Node, comptime root: u32, comptime protocol: i32) void {
    const Pair = struct { source: u32, target: u32, restricted: bool = true, previous: ?usize = null };
    if (std.mem.eql(u8, Source.cursor_mode, "read") and @hasDecl(Source, "layout_fingerprint")) {
        if (actual[root].fingerprint) |fingerprint|
            if (std.mem.eql(u8, &Source.layout_fingerprint, &fingerprint)) return;
    }
    var pending: []const Pair = &.{.{ .source = Source.schema_id, .target = root }};
    var seen = [_]?usize{null} ** Source.schema_nodes.len;
    seen[Source.schema_id] = 0;
    var index: usize = 0;
    while (index < pending.len) : (index += 1) {
        const pair = pending[index];
        const before = Source.schema_nodes[pair.source];
        const after = actual[pair.target];
        if (index != 0 and std.mem.eql(u8, Source.cursor_mode, "write") and before.destination) {
            if (!after.destination or (!std.mem.eql(u8, before.name, after.name) and !samePlainEncoding(Source.schema_nodes, pair.source, actual, pair.target)))
                @compileError(std.fmt.comptimePrint("{s}: nested destination {s} changed to {s} between protocols {d} and {d}", .{ Source.wire_type_name, before.name, after.name, Source.protocol_number, protocol }));
            continue;
        }
        var before_children = before.children;
        var after_children = after.children;
        const narrowed = pair.restricted and Source.restricted_case != null and Source.restricted_case.?.choice == pair.source;
        if (narrowed) {
            const restricted = Source.restricted_case.?;
            const a = before.choice.?;
            const b = after.choice orelse @compileError("restricted field is no longer a choice");
            if (!std.mem.eql(u8, &a.shape, &b.shape)) @compileError("restricted choice selector changed");
            var source_child: ?u32 = null;
            var target_child: ?u32 = null;
            for (a.branches) |branch| if (std.mem.eql(u8, branch.name, restricted.name)) {
                source_child = branch.node;
            };
            for (b.branches) |branch| if (std.mem.eql(u8, branch.name, restricted.name)) {
                target_child = branch.node;
            };
            before_children = &.{source_child.?};
            after_children = &.{target_child orelse @compileError("destination protocol has no case " ++ restricted.name)};
        } else if (!std.mem.eql(u8, &before.shape, &after.shape) or before.children.len != after.children.len)
            @compileError(std.fmt.comptimePrint("{s} changed between source protocol {d} and target protocol {d}. Supply a compatible concrete writer.", .{ Source.wire_type_name, Source.protocol_number, protocol }));
        for (before_children, after_children) |a, b| {
            const restricted = pair.restricted and !narrowed and a != Source.schema_id;
            var visited = false;
            var previous = seen[a];
            while (previous) |position| {
                visited = visited or (pending[position].target == b and pending[position].restricted == restricted);
                previous = pending[position].previous;
            }
            if (!visited) {
                pending = pending ++ .{Pair{ .source = a, .target = b, .restricted = restricted, .previous = seen[a] }};
                seen[a] = pending.len - 1;
            }
        }
    }
}

/// Renaming a plain named record does not change its encoding. Tagged records
/// retain their identity because their symbolic tag keys include that name.
pub fn samePlainEncoding(comptime a: []const Node, comptime ai: u32, comptime b: []const Node, comptime bi: u32) bool {
    if (a[ai].fingerprint == null or b[bi].fingerprint == null or
        !std.mem.eql(u8, &a[ai].fingerprint.?, &b[bi].fingerprint.?)) return false;
    var seen = [_]bool{false} ** a.len;
    var pending: [a.len]u32 = undefined;
    pending[0] = ai;
    seen[ai] = true;
    var count: usize = 1;
    var at: usize = 0;
    while (at < count) : (at += 1) {
        const node = a[pending[at]];
        if (node.choice != null) return false;
        for (node.children) |child| {
            if (seen[child]) continue;
            seen[child] = true;
            pending[count] = child;
            count += 1;
        }
    }
    return true;
}

pub fn destinationWriter(comptime Wire: type, comptime Source: type) ?type {
    @setEvalBranchQuota(100_000);
    if (Wire.namedWriter(Source.wire_type_name)) |Writer| return Writer;
    for (@typeInfo(Wire.NamedWriters).@"struct".decls) |decl| {
        const Writer = @field(Wire.NamedWriters, decl.name);
        if (samePlainEncoding(Source.schema_nodes, Source.schema_id, Writer.schema_nodes, Writer.schema_id)) return Writer;
    }
    return null;
}
