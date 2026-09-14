const std = @import("std");
const sessions = @import("sessions");
const minecraft = @import("minecraft");
const protocols = @import("protocols");

pub const Input = struct {
    pub const id = "minecraft:input";

    pub const Configuration = struct { packets_per_connection: usize = 128 };

    pub const Dependencies = struct { sessions: *sessions.Service };

    const Record = struct {
        handle: ?sessions.Handle = null,
        values: []minecraft.Input,
        start: usize = 0,
        count: usize = 0,
        rejected: bool = false,
    };

    deps: Dependencies,
    records: []Record,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Input {
        if (config.packets_per_connection == 0 or config.packets_per_connection > 4096) return error.InvalidConfiguration;

        const self = try allocator.create(Input);
        const records = try allocator.alloc(Record, deps.sessions.config.connections);
        const packets = try allocator.alloc(minecraft.Input, records.len * config.packets_per_connection);

        for (records, 0..) |*record, index|
            record.* = .{ .values = packets[index * config.packets_per_connection ..][0..config.packets_per_connection] };

        self.* = .{ .deps = deps, .records = records };
        return self;
    }

    pub fn tick(self: *Input) void {
        for (self.records) |*record| {
            record.count = 0;
            record.start = 0;
            record.rejected = false;
        }

        for (self.deps.sessions.input_events) |event| {
            if (event != .input) continue;

            const input = event.input;
            const record = &self.records[input.handle.index];
            record.handle = input.handle;
            if (record.rejected) continue;

            var bytes = input.bytes;

            while (bytes.len != 0) {
                if (record.count == record.values.len) {
                    record.rejected = true;
                    break;
                }

                const frame = sessions.frame(bytes, self.deps.sessions.config.buffer_bytes) catch unreachable;
                _, const payload = protocols.support.read_varint(bytes[0..frame.length]) catch unreachable;
                bytes = bytes[frame.length..];
                record.values[record.count] = minecraft.Adapter(protocols.wire).decode(input.protocol, payload) catch {
                    record.rejected = true;
                    break;
                };
                record.count += 1;
            }

            if (record.rejected) {
                std.log.warn("event=client_input_rejected connection={d}:{d}", .{ input.handle.index, input.handle.generation });
                self.deps.sessions.disconnect(input.handle);
            }
        }
    }

    /// Payload slices borrow the Session input loan and expire at the end of this tick.
    pub fn values(self: *const Input, handle: sessions.Handle) []const minecraft.Input {
        const record = self.records[handle.index];
        if (record.handle == null or !std.meta.eql(record.handle.?, handle) or record.rejected) return &.{};

        return record.values[record.start..record.count];
    }

    pub fn discard(self: *Input, handle: sessions.Handle, count: usize) void {
        const record = &self.records[handle.index];
        std.debug.assert(record.handle != null and std.meta.eql(record.handle.?, handle));
        std.debug.assert(count <= record.count - record.start);
        record.start += count;
    }
};
