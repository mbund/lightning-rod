const std = @import("std");
const chunks = @import("chunks");
const BlockProperties = @import("block_properties").BlockProperties;
const chunk_delivery = @import("terrain").delivery_cache;
const chunk_encoding = @import("terrain").chunk_encoding;
const protocols = @import("protocols");
const assert = std.debug.assert;

pub const Compiler = struct {
    workspace: *chunk_delivery.Workspace,
    catalog: chunk_delivery.Catalog,
    encoder: *chunk_encoding.Workspace,
    columns: [chunk_delivery.batch_max]chunks.Light.Column = undefined,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, selected: *protocols.Default, blocks: *const BlockProperties) !Compiler {
        var catalog = try chunk_encoding.Workspace.initDeliveryCatalog(allocator, &selected.values);
        _ = try catalog.index(selected.values[0].number);
        const workspace = try chunk_delivery.Workspace.init(allocator, selected.values.len);
        // A prewarm prepares every format the server accepts, not only the one asked for first.
        workspace.eager = true;
        return .{ .workspace = workspace, .catalog = catalog, .encoder = try .init(allocator, 1 << 20, &selected.values, blocks) };
    }

    pub fn capacity(self: *const Compiler) usize {
        assert(self.catalog.initialized and self.catalog.variants.len > 0);
        return chunk_delivery.batch_max;
    }

    pub fn begin(self: *Compiler, columns: []const chunks.Light.Column) !void {
        assert(columns.len <= self.capacity());
        @memcpy(self.columns[0..columns.len], columns);
        self.count = columns.len;
        try self.restart();
    }

    fn restart(self: *Compiler) !void {
        var requests: [chunk_delivery.batch_max]chunk_delivery.Request = undefined;
        for (self.columns[0..self.count], requests[0..self.count]) |column, *request| request.* = .{ .column = column, .protocol = self.catalog.variants[0].codec.number };
        _ = try self.workspace.begin(&self.catalog, requests[0..self.count]);
    }

    pub fn compile(self: *Compiler, terrain: *chunks.Chunks, column: chunks.Light.Column, frame: *const chunks.Light.View) !void {
        // The first format a column lacks compiles every missing one into a single bundle.
        // The rest of the pass finds theirs present, or compiles what did not fit.
        for (self.catalog.variants) |variant| {
            self.encoder.compileFrame(self.workspace, column, frame, variant.codec.number, null) catch |err| switch (err) {
                error.DeliveryDeferred => {
                    if (self.workspace.used == 0) return error.DeliveryRecordTooLarge;
                    try self.finish(terrain);
                    try self.restart();
                    try self.encoder.compileFrame(self.workspace, column, frame, variant.codec.number, null);
                },
                else => return err,
            };
        }
    }

    pub fn finish(self: *Compiler, terrain: *chunks.Chunks) !void {
        try self.workspace.finish(terrain);
    }
};
