const std = @import("std");

const assert = std.debug.assert;

/// I/O and presentation work on the Simulation owner, not additional gameplay ticks.
pub const Work = struct {
    pub const Result = enum { idle, progressed, blocked };

    pub const Task = struct {
        context: *anyopaque,
        maximum_items: usize,
        /// Never process more than the supplied item limit. Blocked requires an external wakeup.
        run: *const fn (*anyopaque, std.Io, usize) anyerror!Result,
    };

    tasks: []Task,
    count: usize = 0,
    next: usize = 0,
    sealed: bool = false,

    pub fn register(self: *Work, task: Task) !void {
        assert(!self.sealed);
        assert(task.maximum_items > 0);
        if (self.count == self.tasks.len) return error.WorkCapacity;
        self.tasks[self.count] = task;
        self.count += 1;
        assert(self.count <= self.tasks.len);
    }

    pub fn progress(self: *Work, io: std.Io) !Result {
        assert(self.sealed);
        assert(self.count <= self.tasks.len);
        var result: Result = .idle;

        for (0..self.count) |_| {
            const task = self.tasks[self.next];
            self.next = (self.next + 1) % self.count;

            switch (try task.run(task.context, io, task.maximum_items)) {
                .progressed => return .progressed,
                .blocked => result = .blocked,
                .idle => {},
            }
        }

        return result;
    }
};
