const builtin = @import("builtin");
const handoff = @import("restart_handoff.zig");

pub const section_name = ".lightning_rod.resume";
pub const format_version: u16 = 2;
pub const maximum_protocols = 256;
pub const envelope_version: u16 = handoff.version;
pub const magic = [8]u8{ 'L', 'R', 'R', 'E', 'S', 'U', 'M', 'E' };

pub const Record = extern struct {
    magic_bytes: [8]u8 = magic,
    format: u16 = format_version,
    envelope: u16 = envelope_version,
    elf_machine: u16,
    session_id: u32,
    session_version: u16,
    protocol_count: u16,
    connection_capacity: u32,
    continuation_capacity: u32,
    handoff_capacity: u32,
    protocols: [maximum_protocols]i32 = @splat(0),
};

pub fn make(
    comptime selected: anytype,
    comptime session_id: u32,
    comptime session_version: u16,
    comptime connection_capacity: usize,
    comptime continuation_capacity: usize,
    comptime handoff_capacity: usize,
) Record {
    if (selected.len == 0 or selected.len > maximum_protocols)
        @compileError("resume manifest protocol count exceeds its fixed capacity");
    if (continuation_capacity > @as(usize, @intCast(@as(u32, 0xffff_ffff))))
        @compileError("resume continuation capacity exceeds u32");
    if (connection_capacity > @as(usize, @intCast(@as(u32, 0xffff_ffff))))
        @compileError("resume connection capacity exceeds u32");
    if (handoff_capacity > @as(usize, @intCast(@as(u32, 0xffff_ffff))))
        @compileError("resume handoff capacity exceeds u32");
    var result = Record{
        .elf_machine = machine(),
        .session_id = session_id,
        .session_version = session_version,
        .protocol_count = selected.len,
        .connection_capacity = @intCast(connection_capacity),
        .continuation_capacity = @intCast(continuation_capacity),
        .handoff_capacity = @intCast(handoff_capacity),
    };
    inline for (selected, 0..) |protocol, index| result.protocols[index] = protocol;
    return result;
}

pub fn machine() u16 {
    return switch (builtin.target.cpu.arch) {
        .x86_64 => 62,
        .aarch64 => 183,
        .riscv64 => 243,
        else => @compileError("re-exec manifest needs an ELF machine number for this target"),
    };
}
