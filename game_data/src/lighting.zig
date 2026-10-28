const std = @import("std");
const lighting = @import("lighting");

pub fn Data(comptime expected_states: usize, comptime bytes: []const u8) type {
    return struct {
        pub fn init(allocator: std.mem.Allocator) !lighting.Registry {
            var reader = std.Io.Reader.fixed(bytes);
            if (!std.mem.eql(u8, try reader.take(8), "LRLIGHT1")) return error.InvalidLightingSnapshot;
            const count = try reader.takeInt(u32, .big);
            const faces = try reader.takeInt(u32, .big);
            if (count != expected_states or faces == 0 or faces > 4096) return error.InvalidLightingRegistry;
            const states = try allocator.alloc(lighting.Properties, count);
            errdefer allocator.free(states);
            for (states) |*state| {
                state.opacity = try reader.takeByte();
                state.emission = try reader.takeByte();
                for (&state.faces) |*face| face.* = try reader.takeInt(u16, .big);
            }
            const occlusion = try reader.take(@as(usize, faces) * faces);
            if (reader.seek != bytes.len) return error.InvalidLightingSnapshot;
            return .{ .states = states, .faces = faces, .occlusion = occlusion };
        }
    };
}
