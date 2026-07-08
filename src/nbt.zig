const std = @import("std");

pub const Error = error{
    EndOfStream,
    NegativeLength,
    InvalidNbtTag,
    InvalidNbtAccess,
    InvalidWriterState,
    NbtDepthLimit,
    NbtNodeLimit,
    LengthOverflow,
    NameTooLong,
    TooManyItems,
    MissingItems,
};

pub const Tag = enum(u8) {
    end = 0,
    byte = 1,
    short = 2,
    int = 3,
    long = 4,
    float = 5,
    double = 6,
    byte_array = 7,
    string = 8,
    list = 9,
    compound = 10,
    int_array = 11,
    long_array = 12,

    pub fn fromByte(byte: u8) Error!Tag {
        return switch (byte) {
            0 => .end,
            1 => .byte,
            2 => .short,
            3 => .int,
            4 => .long,
            5 => .float,
            6 => .double,
            7 => .byte_array,
            8 => .string,
            9 => .list,
            10 => .compound,
            11 => .int_array,
            12 => .long_array,
            else => error.InvalidNbtTag,
        };
    }

    pub fn is_container(self: Tag) bool {
        return self == .compound or self == .list;
    }

    pub fn scalar_payload_size(self: Tag) ?usize {
        return switch (self) {
            .byte => 1,
            .short => 2,
            .int, .float => 4,
            .long, .double => 8,
            else => null,
        };
    }
};

pub const Value = union(enum) {
    none,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    bytes: []const u8,
    string: []const u8,
    int_array: []const u8,
    long_array: []const u8,
    list: ListInfo,
};

pub const ListInfo = struct {
    child_tag: Tag,
    len: usize,
};

pub const Node = struct {
    tag: Tag = .end,
    parent: ?u32 = null,
    first_child: u32 = empty,
    last_child: u32 = empty,
    next_sibling: u32 = empty,
    child_count: u32 = 0,
    name: []const u8 = &.{},
    payload: []const u8 = &.{},
    value: Value = .none,

    pub const empty = std.math.maxInt(u32);

    pub fn childIterator(self: Node, nodes: []const Node) ChildIterator {
        if (self.child_count == 0) {
            std.debug.assert(self.first_child == empty);
            std.debug.assert(self.last_child == empty);
        } else {
            std.debug.assert(self.first_child != empty);
            std.debug.assert(self.last_child != empty);
            std.debug.assert(self.first_child < nodes.len);
            std.debug.assert(self.last_child < nodes.len);
        }
        return .{
            .nodes = nodes,
            .next_index = self.first_child,
            .remaining = self.child_count,
        };
    }

    pub fn childNamed(self: Node, nodes: []const Node, name: []const u8) ?Node {
        std.debug.assert(self.tag == .compound);
        var it = self.childIterator(nodes);
        while (it.next()) |child| {
            if (std.mem.eql(u8, child.name, name)) return child;
        }
        return null;
    }

    pub fn expectTag(self: Node, tag: Tag) Error!Node {
        if (self.tag != tag) return error.InvalidNbtAccess;
        return self;
    }

    pub fn byte(self: Node) Error!i8 {
        _ = try self.expectTag(.byte);
        return self.value.byte;
    }

    pub fn short(self: Node) Error!i16 {
        _ = try self.expectTag(.short);
        return self.value.short;
    }

    pub fn int(self: Node) Error!i32 {
        _ = try self.expectTag(.int);
        return self.value.int;
    }

    pub fn long(self: Node) Error!i64 {
        _ = try self.expectTag(.long);
        return self.value.long;
    }

    pub fn float(self: Node) Error!f32 {
        _ = try self.expectTag(.float);
        return self.value.float;
    }

    pub fn double(self: Node) Error!f64 {
        _ = try self.expectTag(.double);
        return self.value.double;
    }

    pub fn string(self: Node) Error![]const u8 {
        _ = try self.expectTag(.string);
        return self.value.string;
    }

    pub fn byteArray(self: Node) Error![]const u8 {
        _ = try self.expectTag(.byte_array);
        return self.value.bytes;
    }

    pub fn intArray(self: Node) Error!IntArray {
        _ = try self.expectTag(.int_array);
        return .{ .bytes = self.value.int_array };
    }

    pub fn longArray(self: Node) Error!LongArray {
        _ = try self.expectTag(.long_array);
        return .{ .bytes = self.value.long_array };
    }

    pub fn listInfo(self: Node) Error!ListInfo {
        _ = try self.expectTag(.list);
        return self.value.list;
    }
};

pub const ChildIterator = struct {
    nodes: []const Node,
    next_index: u32,
    remaining: u32,

    pub fn next(self: *ChildIterator) ?Node {
        if (self.remaining == 0) {
            std.debug.assert(self.next_index == Node.empty);
            return null;
        }
        std.debug.assert(self.next_index != Node.empty);
        std.debug.assert(self.next_index < self.nodes.len);
        const node = self.nodes[self.next_index];
        self.next_index = node.next_sibling;
        self.remaining -= 1;
        if (self.remaining == 0) {
            std.debug.assert(self.next_index == Node.empty);
        }
        return node;
    }
};

pub const IntArray = struct {
    bytes: []const u8,

    pub fn len(self: IntArray) usize {
        std.debug.assert(self.bytes.len % 4 == 0);
        return self.bytes.len / 4;
    }

    pub fn get(self: IntArray, index: usize) i32 {
        std.debug.assert(index < self.len());
        return std.mem.readInt(i32, self.bytes[index * 4 ..][0..4], .big);
    }

    pub fn iterator(self: IntArray) IntArrayIterator {
        return .{ .bytes = self.bytes };
    }
};

pub const IntArrayIterator = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn next(self: *IntArrayIterator) ?i32 {
        if (self.index == self.bytes.len) return null;
        std.debug.assert(self.index < self.bytes.len);
        const value = std.mem.readInt(i32, self.bytes[self.index..][0..4], .big);
        self.index += 4;
        return value;
    }
};

pub const LongArray = struct {
    bytes: []const u8,

    pub fn len(self: LongArray) usize {
        std.debug.assert(self.bytes.len % 8 == 0);
        return self.bytes.len / 8;
    }

    pub fn get(self: LongArray, index: usize) i64 {
        std.debug.assert(index < self.len());
        return std.mem.readInt(i64, self.bytes[index * 8 ..][0..8], .big);
    }

    pub fn iterator(self: LongArray) LongArrayIterator {
        return .{ .bytes = self.bytes };
    }
};

pub const LongArrayIterator = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn next(self: *LongArrayIterator) ?i64 {
        if (self.index == self.bytes.len) return null;
        std.debug.assert(self.index < self.bytes.len);
        const value = std.mem.readInt(i64, self.bytes[self.index..][0..8], .big);
        self.index += 8;
        return value;
    }
};

pub const Document = struct {
    buffer: []const u8,
    nodes: []const Node,
    root: u32,
    rest: []const u8,

    pub fn root_node(self: Document) Node {
        std.debug.assert(self.root < self.nodes.len);
        return self.nodes[self.root];
    }

    pub fn consumed(self: Document) []const u8 {
        return self.buffer[0 .. self.buffer.len - self.rest.len];
    }

    pub fn childNamed(self: Document, name: []const u8) ?Node {
        return self.root_node().childNamed(self.nodes, name);
    }
};

const FrameKind = enum { compound, list };

pub const Frame = struct {
    kind: FrameKind,
    node: u32,
    payload_start: usize = 0,
    child_tag: Tag = .end,
    remaining: usize = 0,
};

const Header = struct {
    tag: Tag,
    name: []const u8,
    payload_offset: usize,
};

pub fn scan_named(buffer: []const u8, nodes: []Node, stack: []Frame) Error!Document {
    return scan(buffer, true, nodes, stack);
}

pub fn scan_anonymous(buffer: []const u8, nodes: []Node, stack: []Frame) Error!Document {
    return scan(buffer, false, nodes, stack);
}

pub fn skip_named(buffer: []const u8, stack: []Frame) Error![]const u8 {
    return skip(buffer, true, stack);
}

pub fn skip_anonymous(buffer: []const u8, stack: []Frame) Error![]const u8 {
    return skip(buffer, false, stack);
}

pub fn skip_optional(buffer: []const u8, stack: []Frame) Error![]const u8 {
    if (buffer.len == 0) return error.EndOfStream;
    if (buffer[0] == @intFromEnum(Tag.end)) return buffer[1..];
    return skip_anonymous(buffer, stack);
}

pub const Scanner = struct {
    nodes: []Node,
    stack: []Frame,

    pub fn init(nodes: []Node, stack: []Frame) Scanner {
        std.debug.assert(nodes.len > 0);
        std.debug.assert(stack.len > 0);
        return .{ .nodes = nodes, .stack = stack };
    }

    pub fn scanNamed(self: Scanner, buffer: []const u8) Error!Document {
        return scan_named(buffer, self.nodes, self.stack);
    }

    pub fn scanAnonymous(self: Scanner, buffer: []const u8) Error!Document {
        return scan_anonymous(buffer, self.nodes, self.stack);
    }

    pub fn skipNamed(self: Scanner, buffer: []const u8) Error![]const u8 {
        return skip_named(buffer, self.stack);
    }

    pub fn skipAnonymous(self: Scanner, buffer: []const u8) Error![]const u8 {
        return skip_anonymous(buffer, self.stack);
    }

    pub fn skipOptional(self: Scanner, buffer: []const u8) Error![]const u8 {
        return skip_optional(buffer, self.stack);
    }
};

const WriteFrameKind = enum { compound, list };

pub const WriteFrame = struct {
    kind: WriteFrameKind,
    child_tag: Tag = .end,
    remaining: usize = 0,
};

pub const Writer = struct {
    buffer: []u8,
    rest: []u8,
    frames: []WriteFrame,
    frame_count: usize = 0,
    root_written: bool = false,

    pub fn init(buffer: []u8, frames: []WriteFrame) Writer {
        std.debug.assert(buffer.len > 0);
        return .{
            .buffer = buffer,
            .rest = buffer,
            .frames = frames,
        };
    }

    pub fn written(self: Writer) []u8 {
        std.debug.assert(self.rest.len <= self.buffer.len);
        return self.buffer[0 .. self.buffer.len - self.rest.len];
    }

    pub fn finish(self: Writer) Error![]u8 {
        if (!self.root_written) return error.InvalidWriterState;
        if (self.frame_count != 0) return error.MissingItems;
        return self.written();
    }

    pub fn beginNamedCompound(self: *Writer, name: []const u8) Error!void {
        try self.requireNamedField();
        try self.writeNamedHeader(.compound, name);
        try self.push(.{ .kind = .compound });
    }

    pub fn beginAnonymousCompound(self: *Writer) Error!void {
        try self.requireRoot();
        try self.writeTag(.compound);
        self.root_written = true;
        try self.push(.{ .kind = .compound });
    }

    pub fn beginAnonymousList(self: *Writer, child_tag: Tag, len: usize) Error!void {
        if (child_tag == .end and len != 0) return error.InvalidWriterState;
        try self.requireRoot();
        try self.writeTag(.list);
        try self.writeListHeader(child_tag, len);
        self.root_written = true;
        try self.push(.{ .kind = .list, .child_tag = child_tag, .remaining = len });
    }

    pub fn beginCompoundElement(self: *Writer) Error!void {
        try self.beginListElement(.compound);
        try self.push(.{ .kind = .compound });
    }

    pub fn endCompound(self: *Writer) Error!void {
        const frame = try self.pop(.compound);
        std.debug.assert(frame.kind == .compound);
        try self.writeTag(.end);
    }

    pub fn beginNamedList(self: *Writer, name: []const u8, child_tag: Tag, len: usize) Error!void {
        if (child_tag == .end and len != 0) return error.InvalidWriterState;
        try self.requireNamedField();
        try self.writeNamedHeader(.list, name);
        try self.writeListHeader(child_tag, len);
        try self.push(.{ .kind = .list, .child_tag = child_tag, .remaining = len });
    }

    pub fn beginListElementList(self: *Writer, child_tag: Tag, len: usize) Error!void {
        if (child_tag == .end and len != 0) return error.InvalidWriterState;
        try self.beginListElement(.list);
        try self.writeListHeader(child_tag, len);
        try self.push(.{ .kind = .list, .child_tag = child_tag, .remaining = len });
    }

    pub fn endList(self: *Writer) Error!void {
        if (self.frame_count == 0) return error.InvalidWriterState;
        const frame = self.frames[self.frame_count - 1];
        if (frame.kind != .list) return error.InvalidWriterState;
        if (frame.remaining != 0) return error.MissingItems;
        self.frame_count -= 1;
    }

    pub fn putByte(self: *Writer, name: []const u8, value: i8) Error!void {
        try self.writeNamedHeader(.byte, name);
        try self.writeInt(i8, value);
    }

    pub fn putShort(self: *Writer, name: []const u8, value: i16) Error!void {
        try self.writeNamedHeader(.short, name);
        try self.writeInt(i16, value);
    }

    pub fn putInt(self: *Writer, name: []const u8, value: i32) Error!void {
        try self.writeNamedHeader(.int, name);
        try self.writeInt(i32, value);
    }

    pub fn putLong(self: *Writer, name: []const u8, value: i64) Error!void {
        try self.writeNamedHeader(.long, name);
        try self.writeInt(i64, value);
    }

    pub fn putFloat(self: *Writer, name: []const u8, value: f32) Error!void {
        try self.writeNamedHeader(.float, name);
        try self.writeInt(u32, @bitCast(value));
    }

    pub fn putDouble(self: *Writer, name: []const u8, value: f64) Error!void {
        try self.writeNamedHeader(.double, name);
        try self.writeInt(u64, @bitCast(value));
    }

    pub fn putString(self: *Writer, name: []const u8, value: []const u8) Error!void {
        try self.writeNamedHeader(.string, name);
        try self.writeStringPayload(value);
    }

    pub fn putByteArray(self: *Writer, name: []const u8, value: []const u8) Error!void {
        try self.writeNamedHeader(.byte_array, name);
        try self.writeCount(value.len);
        try self.writeBytes(value);
    }

    pub fn putIntArray(self: *Writer, name: []const u8, values: []const i32) Error!void {
        try self.writeNamedHeader(.int_array, name);
        try self.writeCount(values.len);
        for (values) |value| try self.writeInt(i32, value);
    }

    pub fn putLongArray(self: *Writer, name: []const u8, values: []const i64) Error!void {
        try self.writeNamedHeader(.long_array, name);
        try self.writeCount(values.len);
        for (values) |value| try self.writeInt(i64, value);
    }

    pub fn putAnonymousByte(self: *Writer, value: i8) Error!void {
        try self.writeAnonymousHeader(.byte);
        try self.writeInt(i8, value);
    }

    pub fn putAnonymousShort(self: *Writer, value: i16) Error!void {
        try self.writeAnonymousHeader(.short);
        try self.writeInt(i16, value);
    }

    pub fn putAnonymousInt(self: *Writer, value: i32) Error!void {
        try self.writeAnonymousHeader(.int);
        try self.writeInt(i32, value);
    }

    pub fn putAnonymousLong(self: *Writer, value: i64) Error!void {
        try self.writeAnonymousHeader(.long);
        try self.writeInt(i64, value);
    }

    pub fn putAnonymousFloat(self: *Writer, value: f32) Error!void {
        try self.writeAnonymousHeader(.float);
        try self.writeInt(u32, @bitCast(value));
    }

    pub fn putAnonymousDouble(self: *Writer, value: f64) Error!void {
        try self.writeAnonymousHeader(.double);
        try self.writeInt(u64, @bitCast(value));
    }

    pub fn putAnonymousString(self: *Writer, value: []const u8) Error!void {
        try self.writeAnonymousHeader(.string);
        try self.writeStringPayload(value);
    }

    pub fn putByteElement(self: *Writer, value: i8) Error!void {
        try self.beginListElement(.byte);
        try self.writeInt(i8, value);
    }

    pub fn putShortElement(self: *Writer, value: i16) Error!void {
        try self.beginListElement(.short);
        try self.writeInt(i16, value);
    }

    pub fn putIntElement(self: *Writer, value: i32) Error!void {
        try self.beginListElement(.int);
        try self.writeInt(i32, value);
    }

    pub fn putLongElement(self: *Writer, value: i64) Error!void {
        try self.beginListElement(.long);
        try self.writeInt(i64, value);
    }

    pub fn putFloatElement(self: *Writer, value: f32) Error!void {
        try self.beginListElement(.float);
        try self.writeInt(u32, @bitCast(value));
    }

    pub fn putDoubleElement(self: *Writer, value: f64) Error!void {
        try self.beginListElement(.double);
        try self.writeInt(u64, @bitCast(value));
    }

    pub fn putStringElement(self: *Writer, value: []const u8) Error!void {
        try self.beginListElement(.string);
        try self.writeStringPayload(value);
    }

    pub fn putByteArrayElement(self: *Writer, value: []const u8) Error!void {
        try self.beginListElement(.byte_array);
        try self.writeCount(value.len);
        try self.writeBytes(value);
    }

    pub fn putIntArrayElement(self: *Writer, values: []const i32) Error!void {
        try self.beginListElement(.int_array);
        try self.writeCount(values.len);
        for (values) |value| try self.writeInt(i32, value);
    }

    pub fn putLongArrayElement(self: *Writer, values: []const i64) Error!void {
        try self.beginListElement(.long_array);
        try self.writeCount(values.len);
        for (values) |value| try self.writeInt(i64, value);
    }

    fn requireRoot(self: Writer) Error!void {
        if (self.frame_count != 0) return error.InvalidWriterState;
        if (self.root_written) return error.InvalidWriterState;
    }

    fn requireNamedField(self: Writer) Error!void {
        if (self.frame_count == 0) {
            if (self.root_written) return error.InvalidWriterState;
            return;
        }
        const frame = self.frames[self.frame_count - 1];
        if (frame.kind != .compound) return error.InvalidWriterState;
    }

    fn beginListElement(self: *Writer, tag: Tag) Error!void {
        if (self.frame_count == 0) return error.InvalidWriterState;
        var frame = &self.frames[self.frame_count - 1];
        if (frame.kind != .list) return error.InvalidWriterState;
        if (frame.child_tag != tag) return error.InvalidWriterState;
        if (frame.remaining == 0) return error.TooManyItems;
        frame.remaining -= 1;
    }

    fn push(self: *Writer, frame: WriteFrame) Error!void {
        if (self.frame_count == self.frames.len) return error.NbtDepthLimit;
        self.frames[self.frame_count] = frame;
        self.frame_count += 1;
    }

    fn pop(self: *Writer, kind: WriteFrameKind) Error!WriteFrame {
        if (self.frame_count == 0) return error.InvalidWriterState;
        const frame = self.frames[self.frame_count - 1];
        if (frame.kind != kind) return error.InvalidWriterState;
        if (frame.kind == .list and frame.remaining != 0) return error.MissingItems;
        self.frame_count -= 1;
        return frame;
    }

    fn writeNamedHeader(self: *Writer, tag: Tag, name: []const u8) Error!void {
        try self.requireNamedField();
        try self.writeTag(tag);
        try self.writeStringPayload(name);
        if (self.frame_count == 0) self.root_written = true;
    }

    fn writeAnonymousHeader(self: *Writer, tag: Tag) Error!void {
        try self.requireRoot();
        try self.writeTag(tag);
        self.root_written = true;
    }

    fn writeListHeader(self: *Writer, child_tag: Tag, len: usize) Error!void {
        try self.writeTag(child_tag);
        try self.writeCount(len);
    }

    fn writeTag(self: *Writer, tag: Tag) Error!void {
        try self.writeByte(@intFromEnum(tag));
    }

    fn writeCount(self: *Writer, len: usize) Error!void {
        if (len > @as(usize, @intCast(std.math.maxInt(i32)))) return error.LengthOverflow;
        try self.writeInt(i32, @intCast(len));
    }

    fn writeStringPayload(self: *Writer, value: []const u8) Error!void {
        if (value.len > std.math.maxInt(u16)) return error.NameTooLong;
        try self.writeInt(u16, @intCast(value.len));
        try self.writeBytes(value);
    }

    fn writeInt(self: *Writer, comptime T: type, value: T) Error!void {
        const size = @divExact(@typeInfo(T).int.bits, 8);
        if (self.rest.len < size) return error.EndOfStream;
        std.mem.writeInt(T, self.rest[0..size], value, .big);
        self.rest = self.rest[size..];
    }

    fn writeByte(self: *Writer, value: u8) Error!void {
        if (self.rest.len == 0) return error.EndOfStream;
        self.rest[0] = value;
        self.rest = self.rest[1..];
    }

    fn writeBytes(self: *Writer, bytes: []const u8) Error!void {
        if (self.rest.len < bytes.len) return error.EndOfStream;
        @memcpy(self.rest[0..bytes.len], bytes);
        self.rest = self.rest[bytes.len..];
    }
};

fn scan(buffer: []const u8, named: bool, nodes: []Node, stack: []Frame) Error!Document {
    std.debug.assert(nodes.len > 0);
    var offset: usize = 0;
    var node_count: usize = 0;
    var stack_len: usize = 0;

    const root_header = try read_header(buffer, &offset, named);
    if (root_header.tag == .end) {
        const root = append_node(nodes, &node_count, null, root_header.tag, root_header.name, buffer[root_header.payload_offset..offset], .none) catch return error.NbtNodeLimit;
        return .{ .buffer = buffer, .nodes = nodes[0..node_count], .root = root, .rest = buffer[offset..] };
    }

    const root = try append_node(nodes, &node_count, null, root_header.tag, root_header.name, &.{}, .none);
    if (root_header.tag.is_container()) {
        try push_container(buffer, &offset, root_header.tag, root, nodes, stack, &stack_len);
    } else {
        const value = try read_value(buffer, &offset, root_header.tag);
        nodes[root].payload = buffer[root_header.payload_offset..offset];
        nodes[root].value = value;
    }

    while (stack_len != 0) {
        const frame_index = stack_len - 1;
        var frame = &stack[frame_index];

        switch (frame.kind) {
            .compound => {
                if (offset >= buffer.len) return error.EndOfStream;
                const tag = try Tag.fromByte(buffer[offset]);
                offset += 1;
                if (tag == .end) {
                    const parent = frame.node;
                    nodes[parent].payload = buffer[frame.payload_start..offset];
                    stack_len -= 1;
                    continue;
                }

                const name = try read_string_payload(buffer, &offset);
                const payload_start = offset;
                const child = try append_node(nodes, &node_count, frame.node, tag, name, &.{}, .none);
                if (tag.is_container()) {
                    try push_container(buffer, &offset, tag, child, nodes, stack, &stack_len);
                } else {
                    const value = try read_value(buffer, &offset, tag);
                    nodes[child].payload = buffer[payload_start..offset];
                    nodes[child].value = value;
                }
            },
            .list => {
                if (frame.remaining == 0) {
                    nodes[frame.node].payload = buffer[frame.payload_start..offset];
                    stack_len -= 1;
                    continue;
                }

                frame.remaining -= 1;
                const tag = frame.child_tag;
                const payload_start = offset;
                const child = try append_node(nodes, &node_count, frame.node, tag, &.{}, &.{}, .none);
                if (tag.is_container()) {
                    try push_container(buffer, &offset, tag, child, nodes, stack, &stack_len);
                } else {
                    const value = try read_value(buffer, &offset, tag);
                    nodes[child].payload = buffer[payload_start..offset];
                    nodes[child].value = value;
                }
            },
        }
    }

    return .{ .buffer = buffer, .nodes = nodes[0..node_count], .root = root, .rest = buffer[offset..] };
}

fn skip(buffer: []const u8, named: bool, stack: []Frame) Error![]const u8 {
    var offset: usize = 0;
    var stack_len: usize = 0;

    const header = try read_header(buffer, &offset, named);
    if (header.tag == .end) return buffer[offset..];
    if (header.tag.is_container()) {
        try push_skip_container(buffer, &offset, header.tag, stack, &stack_len);
    } else {
        _ = try read_value(buffer, &offset, header.tag);
    }

    while (stack_len != 0) {
        const frame_index = stack_len - 1;
        var frame = &stack[frame_index];

        switch (frame.kind) {
            .compound => {
                if (offset >= buffer.len) return error.EndOfStream;
                const tag = try Tag.fromByte(buffer[offset]);
                offset += 1;
                if (tag == .end) {
                    stack_len -= 1;
                    continue;
                }
                _ = try read_string_payload(buffer, &offset);
                if (tag.is_container()) {
                    try push_skip_container(buffer, &offset, tag, stack, &stack_len);
                } else {
                    _ = try read_value(buffer, &offset, tag);
                }
            },
            .list => {
                if (frame.remaining == 0) {
                    stack_len -= 1;
                    continue;
                }
                frame.remaining -= 1;
                if (frame.child_tag.is_container()) {
                    try push_skip_container(buffer, &offset, frame.child_tag, stack, &stack_len);
                } else {
                    _ = try read_value(buffer, &offset, frame.child_tag);
                }
            },
        }
    }

    return buffer[offset..];
}

fn append_node(nodes: []Node, node_count: *usize, parent: ?u32, tag: Tag, name: []const u8, payload: []const u8, value: Value) Error!u32 {
    if (node_count.* == nodes.len) return error.NbtNodeLimit;
    std.debug.assert(node_count.* < nodes.len);
    const index: u32 = @intCast(node_count.*);
    nodes[node_count.*] = .{
        .tag = tag,
        .parent = parent,
        .first_child = Node.empty,
        .last_child = Node.empty,
        .next_sibling = Node.empty,
        .child_count = 0,
        .name = name,
        .payload = payload,
        .value = value,
    };
    node_count.* += 1;

    if (parent) |p| {
        std.debug.assert(p < node_count.*);
        if (nodes[p].child_count == 0) {
            nodes[p].first_child = index;
            nodes[p].last_child = index;
        } else {
            std.debug.assert(nodes[p].last_child != Node.empty);
            std.debug.assert(nodes[nodes[p].last_child].next_sibling == Node.empty);
            nodes[nodes[p].last_child].next_sibling = index;
            nodes[p].last_child = index;
        }
        nodes[p].child_count += 1;
    }

    return index;
}

fn push_container(buffer: []const u8, offset: *usize, tag: Tag, node: u32, nodes: []Node, stack: []Frame, stack_len: *usize) Error!void {
    std.debug.assert(tag.is_container());
    if (stack_len.* == stack.len) return error.NbtDepthLimit;
    const payload_start = offset.*;
    switch (tag) {
        .compound => {
            nodes[node].payload = buffer[payload_start..payload_start];
            stack[stack_len.*] = .{ .kind = .compound, .node = node, .payload_start = payload_start };
        },
        .list => {
            const child_tag = try read_tag(buffer, offset);
            const len = try read_len_i32(buffer, offset);
            nodes[node].payload = buffer[payload_start..offset.*];
            nodes[node].value = .{ .list = .{ .child_tag = child_tag, .len = len } };
            stack[stack_len.*] = .{ .kind = .list, .node = node, .payload_start = payload_start, .child_tag = child_tag, .remaining = len };
        },
        else => unreachable,
    }
    stack_len.* += 1;
}

fn push_skip_container(buffer: []const u8, offset: *usize, tag: Tag, stack: []Frame, stack_len: *usize) Error!void {
    std.debug.assert(tag.is_container());
    if (stack_len.* == stack.len) return error.NbtDepthLimit;
    switch (tag) {
        .compound => stack[stack_len.*] = .{ .kind = .compound, .node = 0 },
        .list => {
            const child_tag = try read_tag(buffer, offset);
            const len = try read_len_i32(buffer, offset);
            stack[stack_len.*] = .{ .kind = .list, .node = 0, .child_tag = child_tag, .remaining = len };
        },
        else => unreachable,
    }
    stack_len.* += 1;
}

fn read_header(buffer: []const u8, offset: *usize, named: bool) Error!Header {
    const tag = try read_tag(buffer, offset);
    if (tag == .end) return .{ .tag = tag, .name = &.{}, .payload_offset = offset.* };
    const name = if (named) try read_string_payload(buffer, offset) else &.{};
    return .{ .tag = tag, .name = name, .payload_offset = offset.* };
}

fn read_value(buffer: []const u8, offset: *usize, tag: Tag) Error!Value {
    return switch (tag) {
        .end => .none,
        .byte => .{ .byte = @bitCast(try read_u8(buffer, offset)) },
        .short => .{ .short = try read_int(i16, buffer, offset) },
        .int => .{ .int = try read_int(i32, buffer, offset) },
        .long => .{ .long = try read_int(i64, buffer, offset) },
        .float => .{ .float = @bitCast(try read_int(u32, buffer, offset)) },
        .double => .{ .double = @bitCast(try read_int(u64, buffer, offset)) },
        .byte_array => blk: {
            const len = try read_len_i32(buffer, offset);
            break :blk .{ .bytes = try read_bytes(buffer, offset, len) };
        },
        .string => .{ .string = try read_string_payload(buffer, offset) },
        .int_array => blk: {
            const len = try read_len_i32(buffer, offset);
            const bytes = try checked_byte_len(len, 4);
            break :blk .{ .int_array = try read_bytes(buffer, offset, bytes) };
        },
        .long_array => blk: {
            const len = try read_len_i32(buffer, offset);
            const bytes = try checked_byte_len(len, 8);
            break :blk .{ .long_array = try read_bytes(buffer, offset, bytes) };
        },
        .compound, .list => unreachable,
    };
}

fn read_tag(buffer: []const u8, offset: *usize) Error!Tag {
    return Tag.fromByte(try read_u8(buffer, offset));
}

fn read_string_payload(buffer: []const u8, offset: *usize) Error![]const u8 {
    const len = try read_int(u16, buffer, offset);
    return read_bytes(buffer, offset, len);
}

fn read_len_i32(buffer: []const u8, offset: *usize) Error!usize {
    const len = try read_int(i32, buffer, offset);
    if (len < 0) return error.NegativeLength;
    return @intCast(len);
}

fn checked_byte_len(len: usize, element_size: usize) Error!usize {
    return std.math.mul(usize, len, element_size) catch error.LengthOverflow;
}

fn read_bytes(buffer: []const u8, offset: *usize, len: usize) Error![]const u8 {
    if (buffer.len -| offset.* < len) return error.EndOfStream;
    const start = offset.*;
    offset.* += len;
    return buffer[start..offset.*];
}

fn read_u8(buffer: []const u8, offset: *usize) Error!u8 {
    if (offset.* == buffer.len) return error.EndOfStream;
    const value = buffer[offset.*];
    offset.* += 1;
    return value;
}

fn read_int(comptime T: type, buffer: []const u8, offset: *usize) Error!T {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    const bytes = try read_bytes(buffer, offset, size);
    return std.mem.readInt(T, bytes[0..size], .big);
}

test "scan named scalar without allocation" {
    const buf = [_]u8{ 0x03, 0x00, 0x03, 'i', 'n', 't', 0x00, 0x00, 0x00, 0x2f };
    var nodes: [4]Node = undefined;
    var stack: [4]Frame = undefined;

    const doc = try scan_named(&buf, &nodes, &stack);
    const root = doc.root_node();

    try std.testing.expectEqual(Tag.int, root.tag);
    try std.testing.expectEqualStrings("int", root.name);
    try std.testing.expectEqual(@as(i32, 47), root.value.int);
    try std.testing.expectEqual(@as(usize, 0), doc.rest.len);
}

test "scan compound into flat preorder tape" {
    const buf = [_]u8{ 0x0a, 0x00, 0x00, 0x04, 0x00, 0x05, 'f', 'i', 'r', 's', 't', 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xe2, 0x40, 0x05, 0x00, 0x06, 's', 'e', 'c', 'o', 'n', 'd', 0x3f, 0x00, 0x00, 0x00, 0x00 };
    var nodes: [8]Node = undefined;
    var stack: [8]Frame = undefined;

    const doc = try scan_named(&buf, &nodes, &stack);
    const root = doc.root_node();
    var children = root.childIterator(doc.nodes);
    const first = children.next().?;
    const second = children.next().?;

    try std.testing.expectEqual(Tag.compound, root.tag);
    try std.testing.expectEqual(@as(u32, 2), root.child_count);
    try std.testing.expectEqualStrings("first", first.name);
    try std.testing.expectEqual(@as(i64, 123456), first.value.long);
    try std.testing.expectEqualStrings("second", second.name);
    try std.testing.expectEqual(@as(f32, 0.5), second.value.float);
    try std.testing.expect(children.next() == null);
    try std.testing.expectEqual(@as(usize, 0), doc.rest.len);
}

test "nested compound siblings are linked explicitly" {
    const buf = [_]u8{
        0x0a, 0x00, 0x00,
        0x0a, 0x00, 0x01,
        'a',  0x03, 0x00,
        0x01, 'x',  0x00,
        0x00, 0x00, 0x01,
        0x00, 0x03, 0x00,
        0x01, 'b',  0x00,
        0x00, 0x00, 0x02,
        0x00,
    };
    var nodes: [8]Node = undefined;
    var stack: [8]Frame = undefined;

    const doc = try scan_named(&buf, &nodes, &stack);
    const root = doc.root_node();
    var root_children = root.childIterator(doc.nodes);
    const a = root_children.next().?;
    const b = root_children.next().?;
    try std.testing.expect(root_children.next() == null);

    try std.testing.expectEqual(Tag.compound, a.tag);
    try std.testing.expectEqualStrings("a", a.name);
    var a_children = a.childIterator(doc.nodes);
    const x = a_children.next().?;
    try std.testing.expect(a_children.next() == null);
    try std.testing.expectEqualStrings("x", x.name);
    try std.testing.expectEqual(@as(i32, 1), x.value.int);

    try std.testing.expectEqualStrings("b", b.name);
    try std.testing.expectEqual(@as(i32, 2), b.value.int);
}

test "skip anonymous list with caller supplied stack" {
    const buf = [_]u8{ 0x09, 0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0xff };
    var stack: [4]Frame = undefined;

    const rest = try skip_anonymous(&buf, &stack);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xff}, rest);
}

test "preallocated node capacity is enforced" {
    const buf = [_]u8{ 0x0a, 0x00, 0x00, 0x03, 0x00, 0x01, 'x', 0x00, 0x00, 0x00, 0x01, 0x00 };
    var nodes: [1]Node = undefined;
    var stack: [4]Frame = undefined;

    try std.testing.expectError(error.NbtNodeLimit, scan_named(&buf, &nodes, &stack));
}

test "typed lookup and numeric array iterators are zero-copy" {
    const buf = [_]u8{
        0x0a, 0x00, 0x00,
        0x03, 0x00, 0x01,
        'x',  0x00, 0x00,
        0x00, 0x2a, 0x08,
        0x00, 0x04, 'n',
        'a',  'm',  'e',
        0x00, 0x03, 'z',
        'e',  'd',  0x0b,
        0x00, 0x04, 'i',
        'n',  't',  's',
        0x00, 0x00, 0x00,
        0x02, 0x00, 0x00,
        0x00, 0x01, 0xff,
        0xff, 0xff, 0xff,
        0x00,
    };
    var nodes: [8]Node = undefined;
    var stack: [8]Frame = undefined;
    const scanner = Scanner.init(&nodes, &stack);

    const doc = try scanner.scanNamed(&buf);
    const x = doc.childNamed("x") orelse return error.InvalidNbtAccess;
    const name = doc.childNamed("name") orelse return error.InvalidNbtAccess;
    const ints = doc.childNamed("ints") orelse return error.InvalidNbtAccess;
    var int_iterator = (try ints.intArray()).iterator();

    try std.testing.expectEqual(@as(i32, 42), try x.int());
    try std.testing.expectEqualStrings("zed", try name.string());
    try std.testing.expectEqual(@as(i32, 1), int_iterator.next().?);
    try std.testing.expectEqual(@as(i32, -1), int_iterator.next().?);
    try std.testing.expect(int_iterator.next() == null);
}

test "writer encodes compound lists and scans back without allocation" {
    var buffer: [256]u8 = undefined;
    var write_stack: [8]WriteFrame = undefined;
    var writer = Writer.init(&buffer, &write_stack);

    try writer.beginNamedCompound("");
    try writer.putInt("DataVersion", 4321);
    try writer.beginNamedList("Pos", .double, 3);
    try writer.putDoubleElement(1.5);
    try writer.putDoubleElement(-2.0);
    try writer.putDoubleElement(0.25);
    try writer.endList();
    try writer.endCompound();
    const encoded = try writer.finish();

    var nodes: [16]Node = undefined;
    var scan_stack: [8]Frame = undefined;
    const doc = try scan_named(encoded, &nodes, &scan_stack);
    const root = doc.root_node();
    const data_version = root.childNamed(doc.nodes, "DataVersion") orelse return error.InvalidNbtAccess;
    const pos = root.childNamed(doc.nodes, "Pos") orelse return error.InvalidNbtAccess;
    const list = try pos.listInfo();
    var pos_it = pos.childIterator(doc.nodes);

    try std.testing.expectEqual(Tag.compound, root.tag);
    try std.testing.expectEqual(@as(i32, 4321), try data_version.int());
    try std.testing.expectEqual(Tag.double, list.child_tag);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@as(f64, 1.5), try pos_it.next().?.double());
    try std.testing.expectEqual(@as(f64, -2.0), try pos_it.next().?.double());
    try std.testing.expectEqual(@as(f64, 0.25), try pos_it.next().?.double());
    try std.testing.expect(pos_it.next() == null);
}

test "writer validates exact list counts" {
    var buffer: [64]u8 = undefined;
    var write_stack: [4]WriteFrame = undefined;
    var writer = Writer.init(&buffer, &write_stack);

    try writer.beginAnonymousList(.int, 1);
    try std.testing.expectError(error.MissingItems, writer.endList());
    try writer.putIntElement(7);
    try std.testing.expectError(error.TooManyItems, writer.putIntElement(8));
    try writer.endList();
    const encoded = try writer.finish();

    var nodes: [4]Node = undefined;
    var scan_stack: [4]Frame = undefined;
    const doc = try scan_anonymous(encoded, &nodes, &scan_stack);
    const root = doc.root_node();
    var children = root.childIterator(doc.nodes);
    try std.testing.expectEqual(@as(i32, 7), try children.next().?.int());
    try std.testing.expect(children.next() == null);
}
