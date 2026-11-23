pub const FileBatch = @import("file_io.zig").FileBatch;
pub const scratch_file = @import("scratch_file.zig");
pub const ScratchFile = scratch_file.ScratchFile;
pub const Memory = @import("memory.zig").Memory;
pub const work = @import("work.zig");
pub const huge_page_allocator = @import("huge_pages.zig").allocator;
pub const BatchIndex = @import("batch_index.zig").BatchIndex;
pub const IndexSet = @import("index_set.zig").IndexSet;
pub const sparse_sets = @import("sparse_sets.zig");
pub const bit_sets = @import("bit_sets.zig");
pub const Mailbox = @import("mailbox.zig").Mailbox;
pub const BuddyAllocator = @import("buddy_allocator.zig").BuddyAllocator;
/// A std.Io for tests, with virtual time and seeded randomness.
pub const DeterministicIo = @import("deterministic_io.zig").DeterministicIo;

test {
    _ = @import("work.zig");
    _ = @import("huge_pages.zig");
    _ = @import("batch_index.zig");
    _ = @import("mailbox.zig");
    _ = @import("buddy_allocator.zig");
    _ = @import("deterministic_io.zig");
    _ = @import("index_set.zig");
    _ = @import("bit_sets.zig");
    _ = @import("sparse_sets.zig");
    _ = @import("file_io.zig");
    _ = @import("scratch_file.zig");
}
