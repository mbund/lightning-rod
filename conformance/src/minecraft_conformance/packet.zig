/// Generated canonicalizers populate this lossless generic packet model.
/// Tests normally use `testing.Packet`, which owns these values and provides
/// extraction helpers, while newly generated packet types need no hand-written
/// union case.
pub const Value = union(enum) {
    literal: []const u8,
};

pub const Field = struct {
    name: []const u8,
    value: Value,
};

pub const Packet = struct {
    name: []const u8,
    fields: []const Field = &.{},
};

pub const Client = struct { name: []const u8 };
pub const Control = enum { disconnect, reconnect };
