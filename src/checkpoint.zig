/// Only the simulation owner may request a save. Ordinary saves do not wait for disk.
pub const Checkpoint = struct {
    requested: bool = false,

    pub fn request(self: *Checkpoint) void {
        self.requested = true;
    }
};
