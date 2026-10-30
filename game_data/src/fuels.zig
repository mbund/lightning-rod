const std = @import("std");

pub fn Data(comptime items: usize, comptime bytes: []const u8) type {
    std.debug.assert(bytes.len >= 16 + items * 4);
    std.debug.assert(std.mem.eql(u8, bytes[0..8], "LRFUEL02"));
    std.debug.assert(std.mem.readInt(u32, bytes[8..12], .big) == items);
    return struct {
        pub const Rule = struct { kind: enum(u8) { item, tag, remove }, ticks: u32, name: []const u8 };
        pub const Iterator = struct {
            reader: std.Io.Reader,
            remaining: u32,

            pub fn next(self: *Iterator) !?Rule {
                if (self.remaining == 0) {
                    if (self.reader.seek != self.reader.end) return error.InvalidFuelSnapshot;
                    return null;
                }
                const kind = try self.reader.takeByte();
                if (kind > 2) return error.InvalidFuelSnapshot;
                const ticks = try self.reader.takeInt(u32, .big);
                const name = try self.reader.take(try self.reader.takeInt(u16, .big));
                self.remaining -= 1;
                return .{ .kind = @enumFromInt(kind), .ticks = ticks, .name = name };
            }
        };

        pub fn rules() Iterator {
            var reader = std.Io.Reader.fixed(bytes[12 + items * 4 ..]);
            const remaining = reader.takeInt(u32, .big) catch unreachable;
            return .{ .reader = reader, .remaining = remaining };
        }

        pub fn remainder(item: u32) ?u32 {
            std.debug.assert(item < items);
            const encoded = std.mem.readInt(i32, bytes[12 + @as(usize, item) * 4 ..][0..4], .big);
            return if (encoded < 0) null else @intCast(encoded);
        }
    };
}
