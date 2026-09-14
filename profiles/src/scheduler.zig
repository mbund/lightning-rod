const std = @import("std");
const rod = @import("lightning_rod");
const sessions = @import("sessions");

const assert = std.debug.assert;

pub fn Scheduler(comptime Plugins: type) type {
    return struct {
        pub const Job = struct {
            simulation: *rod.Simulation(Plugins),
            endpoint: *sessions.Service,
            deadline: i96,
            work: rod.Work.Result = .idle,
            operation: enum { tick, work } = .tick,
            running: bool = false,
            done: std.atomic.Value(bool) = .init(false),
            failure: ?anyerror = null,

            fn run(self: *Job, io: std.Io, wakeup: *std.Io.Event) void {
                defer {
                    self.endpoint.flush();
                    self.done.store(true, .release);
                    wakeup.set(io);
                }

                switch (self.operation) {
                    .tick => {
                        self.endpoint.beginTick();
                        var completed = false;
                        defer self.endpoint.endTick(completed);
                        self.simulation.tick() catch |err| {
                            self.failure = err;
                            return;
                        };
                        completed = true;
                        const now = std.Io.Clock.now(.awake, io).nanoseconds;
                        self.deadline = @max(self.deadline + 50 * std.time.ns_per_ms, now);
                        self.work = .progressed;

                        if (self.simulation.last_tick_ns > 50 * std.time.ns_per_ms)
                            std.log.warn("event=slow_tick tick={d} ns={d}", .{ self.simulation.completed_tick, self.simulation.last_tick_ns });
                    },
                    .work => {
                        self.work = self.simulation.progress() catch |err| {
                            self.failure = err;
                            return;
                        };

                        if (self.simulation.work_ns > 50 * std.time.ns_per_ms) std.log.warn("event=slow_tick work_ns={d}", .{self.simulation.work_ns});
                    },
                }
            }
        };

        pub const Slot = struct {
            future: ?std.Io.Future(void) = null,
            job: ?*Job = null,
        };

        /// Each job's entire tick runs on one worker thread.
        pub fn run(io: std.Io, jobs: []Job, slots: []Slot, stop: *std.atomic.Value(bool), wakeup: *std.Io.Event) !void {
            assert(jobs.len > 0 and slots.len > 0);

            for (jobs) |job| assert(!job.running);

            for (slots) |slot| assert(slot.job == null and slot.future == null);
            defer for (slots) |*slot| {
                if (slot.future) |*future| future.await(io);

                if (slot.job) |job| job.running = false;
                slot.* = .{};
            };
            var next: usize = 0;

            while (!stop.load(.acquire)) {
                wakeup.reset();

                for (slots) |*slot| {
                    const job = slot.job orelse continue;
                    if (!job.done.load(.acquire)) continue;

                    if (slot.future) |*future| future.await(io);
                    slot.* = .{};
                    job.running = false;
                    if (job.failure) |err| return err;
                }

                const now = std.Io.Clock.now(.awake, io).nanoseconds;

                for (slots) |*slot| {
                    if (slot.job != null) continue;

                    var selected: ?*Job = null;

                    for (0..jobs.len) |_| {
                        const job = &jobs[next];
                        next = (next + 1) % jobs.len;
                        if (job.running) continue;
                        if (job.deadline <= now) {
                            selected = job;
                            job.operation = .tick;
                            break;
                        }
                    }

                    if (selected == null) for (0..jobs.len) |_| {
                        const job = &jobs[next];
                        next = (next + 1) % jobs.len;
                        if (job.running) continue;
                        if (job.work == .progressed or (job.work == .blocked and job.endpoint.output_progress.isSet())) {
                            selected = job;
                            job.operation = .work;
                            break;
                        }
                    };

                    const job = selected orelse break;
                    job.endpoint.output_progress.reset();
                    job.done.store(false, .monotonic);
                    job.running = true;
                    slot.job = job;
                    slot.future = io.concurrent(Job.run, .{ job, io, wakeup }) catch {
                        Job.run(job, io, wakeup);
                        continue;
                    };
                }

                var deadline = now + 50 * std.time.ns_per_ms;
                var available = false;

                for (slots) |slot| available = available or slot.job == null;

                if (available) for (jobs) |job| {
                    if (!job.running) deadline = @min(deadline, job.deadline);
                };

                wakeup.waitTimeout(io, .{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = deadline } } }) catch |err| switch (err) {
                    error.Timeout => {},
                    else => return err,
                };
            }
        }
    };
}
