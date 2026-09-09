pub const min_y: i16 = -64;
pub const section_count: usize = 24;
pub const top_y: i16 = min_y + @as(i16, @intCast(section_count * 16)) - 1;
pub const username_bytes: usize = 16;
