test {
    _ = @import("authentication.zig");
    _ = @import("io_uring_transport.zig");
    _ = @import("local_packs.zig");
    _ = @import("logging_stdout.zig");
    _ = @import("reexec.zig");
    _ = @import("shutdown.zig");
    _ = @import("shutdown_posix.zig");
    _ = @import("std_io_transport.zig");
    _ = @import("tui_terminal.zig");
    _ = @import("reexec_executor.zig");
    _ = @import("reexec_handoff_fd.zig");
    _ = @import("reexec_reload.zig");
    _ = @import("restart_handoff.zig");
}
