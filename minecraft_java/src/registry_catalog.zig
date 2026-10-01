const std = @import("std");
const sessions = @import("sessions");

pub fn RegistryCatalog(comptime implementations: anytype) type {
    if (implementations.len == 0) @compileError("select at least one protocol implementation");

    return struct {
        pub const versions = implementations;
        pub const numbers = block: {
            var values: [implementations.len]i32 = undefined;
            for (implementations, &values) |Implementation, *value| value.* = Implementation.protocol_number;
            break :block values;
        };

        const Prepared = block: {
            var types: [implementations.len]type = undefined;
            for (implementations, 0..) |Implementation, index| {
                for (0..index) |previous|
                    if (Implementation.protocol_number == implementations[previous].protocol_number) @compileError("duplicate protocol number");
                types[index] = Implementation.RegistryProvider.PreparedRegistries;
            }
            break :block std.meta.Tuple(&types);
        };

        prepared: Prepared,
        values: [implementations.len]sessions.Protocol,

        pub fn init(allocator: std.mem.Allocator) !@This() {
            var result: @This() = undefined;
            var initialized: usize = 0;
            errdefer inline for (implementations, 0..) |_, index| {
                if (index < initialized) result.prepared[index].deinit(allocator);
            };

            inline for (implementations, 0..) |Implementation, index| {
                result.prepared[index] = try Implementation.RegistryProvider.init(allocator);
                initialized += 1;
                result.values[index] = result.prepared[index].configurationData();
                result.values[index].frame_bound = Implementation.Connection.Wire.frame_bound;
                if (result.values[index].number != Implementation.protocol_number) return error.InvalidProtocolDefinition;
            }
            return result;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            inline for (implementations, 0..) |_, index| self.prepared[index].deinit(allocator);
            self.* = undefined;
        }
    };
}
