const limits = @import("world/limits.zig");

pub const bytes_per_section = 16 * 16 * 16 / 2;
pub const world_section_count = limits.section_count;
pub const protocol_section_count = world_section_count + 2;

pub const Section = extern struct {
    ptr: ?[*]const u8 = null,

    pub fn bytes(self: Section) ?[]const u8 {
        const data = self.ptr orelse return null;
        return data[0..bytes_per_section];
    }
};

pub const Chunk = extern struct {
    chunk_x: i32,
    chunk_z: i32,
    revision: u64,
    sky_mask: u32,
    block_mask: u32,
    empty_sky_mask: u32,
    empty_block_mask: u32,
    sky: [protocol_section_count]Section,
    block: [protocol_section_count]Section,
};

pub const Update = extern struct {
    chunk: *const Chunk,
    sky_changed_mask: u32,
    block_changed_mask: u32,
};

comptime {
    if (protocol_section_count > 32)
        @compileError("light projection masks require at most 32 protocol sections");
}
