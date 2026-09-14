const std = @import("std");

pub const Id = u32;
pub const none = std.math.maxInt(Id);

pub const Kind = enum { pending, constructor, alias, scalar, container, array, optional, choice, holder, holder_set };

pub const Count = union(enum) {
    fixed: usize,
    wire: []const u8,
    field: Selector,
    sentinel: u8,
    high_bit,
};

pub const Selector = struct {
    field: Id = none,
    shift: u7 = 0,
    bits: u7 = 64,
    signed: bool = true,
};

pub const Member = struct {
    name: []const u8,
    bits: u7,
    shift: u7,
    signed: bool,
};

pub const Mapping = struct {
    name: []const u8,
    value: i128,
};

pub const Field = struct {
    name: []const u8,
    node: Id,
    binding: Id = none,
};

pub const Branch = struct {
    name: []const u8,
    node: Id,
    value: i128 = 0,
};

pub const Node = struct {
    kind: Kind = .pending,
    native: bool = false,
    name: []const u8 = "",
    source: std.json.Value = .null,
    scope: usize = 0,
    root: Id = none,
    parent: Id = none,
    position: usize = 0,
    child: Id = none,
    fallback: Id = none,
    codec: []const u8 = "",
    fields: []Field = &.{},
    branches: []Branch = &.{},
    members: []Member = &.{},
    mappings: []Mapping = &.{},
    count: Count = .{ .fixed = 0 },
    selector: Selector = .{},
};

pub const Binding = struct {
    owner: Id,
    field: usize,
};

pub const Scope = struct {
    name: []const u8,
    types: std.StringHashMap(Id),
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    bindings: std.ArrayList(Binding) = .empty,

    pub fn init(allocator: std.mem.Allocator, document: std.json.Value) !Graph {
        var graph = Graph{ .allocator = allocator };
        try graph.addScope("", try get(document, "types"));

        for ([_][]const u8{ "handshaking", "status", "login", "configuration", "play" }) |phase| {
            for ([_][]const u8{ "toServer", "toClient" }) |direction| {
                const name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ phase, direction });
                try graph.addScope(name, try get(try get(try get(document, phase), direction), "types"));
            }
        }

        var index: Id = 0;

        while (index < graph.nodes.items.len) : (index += 1) try graph.normalize(index);

        for (graph.nodes.items) |*node| {
            if (node.child != none) node.child = try graph.payload(node.child);

            if (node.fallback != none) node.fallback = try graph.payload(node.fallback);

            for (node.fields) |*field| if (field.node != none) {
                field.node = try graph.payload(field.node);
            };

            for (node.branches) |*branch| branch.node = try graph.payload(branch.node);
        }

        index = 0;

        while (index < graph.nodes.items.len) : (index += 1) {
            var node = graph.nodes.items[index];
            if (node.kind == .choice) {
                const options = node.source.array.items[1];
                node.selector = try graph.selector(node, try string(try get(options, "compareTo")));
                const binding = graph.bindings.items[node.selector.field];
                const selected = try graph.resolve(graph.nodes.items[binding.owner].fields[binding.field].node);
                const mapped = graph.nodes.items[selected].mappings;

                for (node.branches) |*branch| {
                    var value: ?i128 = null;

                    for (mapped) |mapping| if (std.mem.eql(u8, mapping.name, branch.name)) {
                        value = mapping.value;
                        break;
                    };

                    branch.value = value orelse if (std.mem.eql(u8, branch.name, "true")) 1 else if (std.mem.eql(u8, branch.name, "false")) 0 else std.fmt.parseInt(i128, branch.name, 0) catch return error.InvalidSwitchLabel;
                }
            }

            if ((node.kind == .array or (node.kind == .scalar and (std.mem.eql(u8, node.codec, "buffer") or std.mem.eql(u8, node.codec, "pstring")))) and node.count == .field) {
                node.count = .{ .field = try graph.selector(node, try string(try get(node.source.array.items[1], "count"))) };
            }

            graph.nodes.items[index] = node;
        }

        return graph;
    }

    fn addScope(self: *Graph, name: []const u8, types: std.json.Value) !void {
        var scope = Scope{ .name = name, .types = .init(self.allocator) };
        var entries = (try object(types)).iterator();

        while (entries.next()) |entry| {
            const id: Id = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{
                .name = entry.key_ptr.*,
                .source = entry.value_ptr.*,
                .scope = self.scopes.items.len,
                .root = id,
            });
            try scope.types.put(entry.key_ptr.*, id);
        }

        try self.scopes.append(self.allocator, scope);
    }

    fn add(self: *Graph, parent: Node, enclosing: Id, source: std.json.Value) !Id {
        const id: Id = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .source = source,
            .scope = parent.scope,
            .root = parent.root,
            .parent = enclosing,
            .position = parent.position,
        });
        return id;
    }

    fn normalize(self: *Graph, id: Id) !void {
        var node = self.nodes.items[id];
        const source = node.source;
        if (source == .string) {
            if (std.mem.eql(u8, source.string, "native")) {
                node.native = true;
                node.codec = node.name;
                node.kind = if (isPrimitive(node.name)) .scalar else .constructor;
                if (node.kind == .constructor) {
                    var known = false;

                    for ([_][]const u8{ "pstring", "buffer", "option", "entityMetadataLoop", "topBitSetTerminatedArray", "bitfield", "bitflags", "container", "switch", "array", "registryEntryHolder", "registryEntryHolderSet" }) |name|
                        known = known or std.mem.eql(u8, node.name, name);
                    if (!known) return error.UnsupportedNative;
                }
            } else {
                node.kind = .alias;
                node.child = self.scopes.items[node.scope].types.get(source.string) orelse self.scopes.items[0].types.get(source.string) orelse return error.UnknownReference;
            }

            self.nodes.items[id] = node;
            return;
        }

        const pair = try array(source);
        if (pair.len != 2) return error.InvalidConstructor;

        const constructor = try string(pair[0]);
        const options = pair[1];

        if (std.mem.eql(u8, constructor, "container")) {
            node.kind = .container;
            const fields = try array(options);
            node.fields = try self.allocator.alloc(Field, fields.len);

            for (fields, node.fields, 0..) |field, *result, i| {
                result.* = .{
                    .name = if ((try object(field)).get("name")) |name| try string(name) else try std.fmt.allocPrint(self.allocator, "anon_{}", .{i}),
                    .node = try self.add(node, id, try get(field, "type")),
                };
                self.nodes.items[result.node].position = i;
            }
        } else if (std.mem.eql(u8, constructor, "mapper")) {
            node.kind = .scalar;
            node.codec = try string(try get(options, "type"));
            const mappings = try object(try get(options, "mappings"));
            node.mappings = try self.allocator.alloc(Mapping, mappings.count());

            for (mappings.keys(), mappings.values(), node.mappings) |key, value, *mapping|
                mapping.* = .{ .name = try string(value), .value = try std.fmt.parseInt(i128, key, 0) };
        } else if (std.mem.eql(u8, constructor, "bitfield") or std.mem.eql(u8, constructor, "bitflags")) {
            node.kind = .scalar;
            const flags = std.mem.eql(u8, constructor, "bitflags");
            node.codec = if (flags) try string(try get(options, "type")) else "packed_bits";
            const members = try array(if (flags) try get(options, "flags") else options);
            node.members = try self.allocator.alloc(Member, members.len);
            var total: u8 = 0;

            for (members, node.members, 0..) |member, *result, i| {
                const bits: u7 = if (flags) 1 else @intCast(try integer(try get(member, "size")));
                if (bits == 0 or @as(u16, total) + bits > 64) return error.InvalidBitWidth;
                total += bits;
                result.* = .{
                    .name = if (flags) try string(member) else try string(try get(member, "name")),
                    .bits = bits,
                    .shift = if (flags) @intCast(i) else @intCast(total),
                    .signed = if (flags) false else (try get(member, "signed")).bool,
                };
            }

            if (!flags) for (node.members) |*member| {
                member.shift = @as(u7, @intCast(total)) - member.shift;
            };

            node.count = .{ .fixed = total };
        } else if (std.mem.eql(u8, constructor, "switch")) {
            node.kind = .choice;
            const fields = try object(try get(options, "fields"));
            node.branches = try self.allocator.alloc(Branch, fields.count());

            for (fields.keys(), fields.values(), node.branches) |name, value, *branch|
                branch.* = .{ .name = name, .node = try self.add(node, node.parent, value) };

            if ((try object(options)).get("default")) |fallback| node.fallback = try self.add(node, node.parent, fallback);
        } else if (std.mem.eql(u8, constructor, "option")) {
            node.kind = .optional;
            node.child = try self.add(node, node.parent, options);
        } else if (std.mem.eql(u8, constructor, "array") or std.mem.eql(u8, constructor, "entityMetadataLoop") or std.mem.eql(u8, constructor, "topBitSetTerminatedArray")) {
            node.kind = .array;
            node.child = try self.add(node, node.parent, try get(options, "type"));
            node.count = if (std.mem.eql(u8, constructor, "entityMetadataLoop")) .{ .sentinel = @intCast(try integer(try get(options, "endVal"))) } else if (std.mem.eql(u8, constructor, "topBitSetTerminatedArray")) .high_bit else try count(options);
        } else if (std.mem.eql(u8, constructor, "buffer") or std.mem.eql(u8, constructor, "pstring")) {
            node.kind = .scalar;
            node.codec = constructor;
            node.count = try count(options);
        } else if (std.mem.eql(u8, constructor, "registryEntryHolder") or std.mem.eql(u8, constructor, "registryEntryHolderSet")) {
            const set = std.mem.eql(u8, constructor, "registryEntryHolderSet");
            node.kind = if (set) .holder_set else .holder;
            const otherwise = try get(options, "otherwise");
            node.fields = try self.allocator.alloc(Field, 2);
            node.fields[0] = if (set) .{
                .name = try string(try get(try get(options, "base"), "name")),
                .node = try self.add(node, node.parent, try get(try get(options, "base"), "type")),
            } else .{ .name = try string(try get(options, "baseName")), .node = none };
            node.fields[1] = .{
                .name = try string(try get(otherwise, "name")),
                .node = try self.add(node, node.parent, try get(otherwise, "type")),
            };
        } else {
            std.log.err("unsupported constructor {s} in {s}", .{ constructor, self.nodes.items[node.root].name });
            return error.UnsupportedConstructor;
        }

        self.nodes.items[id] = node;
    }

    pub fn resolve(self: *const Graph, initial: Id) !Id {
        var id = initial;

        for (0..self.nodes.items.len) |_| {
            if (self.nodes.items[id].kind != .alias) return id;
            id = self.nodes.items[id].child;
        }

        return error.ReferenceCycle;
    }

    fn payload(self: *const Graph, initial: Id) !Id {
        const id = try self.resolve(initial);
        if (self.nodes.items[id].kind == .constructor) return error.MissingConstructorArguments;
        return id;
    }

    fn selector(self: *Graph, node: Node, path: []const u8) !Selector {
        var owner = node.parent;
        var available = node.position;
        var rest = path;

        while (std.mem.startsWith(u8, rest, "../")) {
            if (owner == none) return error.UnknownSelector;
            available = self.nodes.items[owner].position;
            owner = self.nodes.items[owner].parent;
            rest = rest[3..];
        }

        if (owner == none) return error.UnknownSelector;

        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;

        for (self.nodes.items[owner].fields, 0..) |*field, index| {
            if (!std.mem.eql(u8, field.name, rest[0..slash])) continue;
            if (index >= available) return error.ForwardSelector;

            if (field.binding == none) {
                field.binding = @intCast(self.bindings.items.len);
                try self.bindings.append(self.allocator, .{ .owner = owner, .field = index });
            }

            var result = Selector{ .field = field.binding };
            if (slash != rest.len) {
                const selected = self.nodes.items[try self.resolve(field.node)];

                for (selected.members) |member| if (std.mem.eql(u8, member.name, rest[slash + 1 ..])) {
                    result.shift = member.shift;
                    result.bits = member.bits;
                    result.signed = member.signed;
                    return result;
                };

                return error.UnknownSelectorMember;
            }

            return result;
        }

        std.log.err("unresolved selector {s} in {s}", .{ path, self.nodes.items[self.nodes.items[owner].root].name });
        return error.UnknownSelector;
    }
};

fn isPrimitive(name: []const u8) bool {
    for ([_][]const u8{ "varint", "varlong", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "bool", "f32", "f64", "UUID", "void", "restBuffer", "nbt", "optionalNbt", "anonymousNbt", "anonOptionalNbt" }) |candidate|
        if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn count(value: std.json.Value) !Count {
    const obj = try object(value);
    if (obj.get("countType")) |codec| return .{ .wire = try string(codec) };

    const length = obj.get("count") orelse return error.MissingCount;
    return switch (length) {
        .integer => |n| if (n >= 0) .{ .fixed = @intCast(n) } else error.NegativeCount,
        .string => .{ .field = .{} },
        else => error.InvalidCount,
    };
}

pub fn object(value: std.json.Value) !std.json.ObjectMap {
    return if (value == .object) value.object else error.ExpectedObject;
}

pub fn array(value: std.json.Value) ![]std.json.Value {
    return if (value == .array) value.array.items else error.ExpectedArray;
}

pub fn string(value: std.json.Value) ![]const u8 {
    return if (value == .string) value.string else error.ExpectedString;
}

pub fn integer(value: std.json.Value) !i64 {
    return if (value == .integer) value.integer else error.ExpectedInteger;
}

pub fn get(value: std.json.Value, name: []const u8) !std.json.Value {
    return (try object(value)).get(name) orelse error.MissingField;
}
