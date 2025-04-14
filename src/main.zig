const std = @import("std");
const http = std.http;

const xev = @import("xev");
const ziro = @import("ziro");
const coro = ziro;
const aio = ziro.asyncio;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tp = try allocator.create(xev.ThreadPool);
    tp.* = xev.ThreadPool.init(.{});

    var loop = try allocator.create(xev.Loop);
    loop.* = try xev.Loop.init(.{ .thread_pool = tp });

    const executor = try allocator.create(aio.Executor);
    executor.* = aio.Executor.init(loop);

    defer {
        loop.deinit();
        tp.shutdown();
        tp.deinit();
        allocator.destroy(tp);
        allocator.destroy(loop);
        allocator.destroy(executor);
    }

    aio.initEnv(.{
        .executor = executor,
        .stack_allocator = allocator,
        .default_stack_size = 1024 * 8,
    });

    try aio.run(executor, mainTask, .{allocator}, null);
}

fn mainTask(allocator: std.mem.Allocator) !void {
    // init a WaitGroup
    var wg = WaitGroup.init(allocator);
    defer wg.deinit();

    const num_tasks: usize = 5;

    const tasks = try allocator.alloc(ziro.Frame, num_tasks);
    defer {
        // deinit coroutine stack
        for (tasks) |t| {
            t.deinit();
        }
        // then free tasks array
        allocator.free(tasks);
    }

    const names = try allocator.alloc([]const u8, num_tasks);
    defer {
        // free each name string
        for (names) |name| {
            allocator.free(name);
        }
        // then free names array
        allocator.free(names);
    }

    // launch a bunch of tasks
    for (0..num_tasks) |i| {
        wg.inc();

        names[i] = try std.fmt.allocPrint(allocator, "Task-{}", .{i});
        const ms: u64 = if (i < num_tasks / 2) 20 else 10;
        // launch a coroutine
        const t = try ziro.xasync(task, .{ &wg, names[i], ms }, null);
        // add the coroutine to array
        tasks[i] = t.frame();
    }

    // wait for all coroutines done
    wg.wait();
}

fn task(wg: *WaitGroup, name: []const u8, delay_ms: u64) !void {
    defer wg.done();

    std.debug.print("{s} starting, will sleep for {}ms\n", .{ name, delay_ms });
    try aio.sleep(null, delay_ms);
    std.debug.print("{s} completed after {}ms\n", .{ name, delay_ms });
}

/// WaitGroup waits for a collection of coroutines to finish.
/// Similar to Go's sync.WaitGroup, it provides a way to wait until
/// all started coroutines complete their work.
pub const WaitGroup = struct {
    counter: std.atomic.Value(usize),
    mutex: std.Thread.Mutex,
    waiters: std.ArrayList(*WaitingCoro),
    allocator: std.mem.Allocator,

    const WaitingCoro = struct {
        frame: coro.Frame,
        signaled: bool,
    };

    /// Initialize a new WaitGroup
    pub fn init(allocator: std.mem.Allocator) WaitGroup {
        return .{
            .counter = std.atomic.Value(usize).init(0),
            .mutex = .{},
            .waiters = std.ArrayList(*WaitingCoro).init(allocator),
            .allocator = allocator,
        };
    }

    /// Clean up resources used by the WaitGroup
    pub fn deinit(self: *WaitGroup) void {
        self.waiters.deinit();
    }

    /// Add adds delta, which may be negative, to the WaitGroup counter.
    /// If the counter becomes zero, all coroutines blocked on Wait are released.
    pub fn add(self: *WaitGroup, delta: usize) void {
        const prev = self.counter.fetchAdd(delta, .monotonic);
        const new_count = prev + delta;

        // If counter is now zero, wake up all waiting coroutines
        if (new_count == 0) {
            self.wakeWaiters();
        }
    }

    /// Increment the WaitGroup counter by one
    pub fn inc(self: *WaitGroup) void {
        _ = self.counter.fetchAdd(1, .monotonic);
    }

    /// Decrement the WaitGroup counter by one
    /// If the counter becomes zero, all coroutines blocked on Wait are released
    pub fn done(self: *WaitGroup) void {
        const prev = self.counter.fetchSub(1, .monotonic);

        // If this was the last counter, wake up all waiting coroutines
        if (prev == 1) {
            self.wakeWaiters();
        } else if (prev == 0) {
            @panic("WaitGroup counter negative");
        }
    }

    /// Wait blocks until the WaitGroup counter is zero
    pub fn wait(self: *WaitGroup) void {
        // Quick path: if counter is already 0, return immediately
        if (self.counter.load(.monotonic) == 0) {
            return;
        }

        // Allocate a waiter structure
        const waiter = self.allocator.create(WaitingCoro) catch @panic("OOM in WaitGroup.wait");
        defer self.allocator.destroy(waiter);

        // Initialize the waiter
        waiter.* = .{
            .frame = coro.xframe(),
            .signaled = false,
        };

        // Add to waiters list
        self.mutex.lock();
        self.waiters.append(waiter) catch @panic("OOM in WaitGroup.wait");
        self.mutex.unlock();

        // Check counter again (in case it became 0 while we were setting up)
        if (self.counter.load(.monotonic) == 0) {
            self.wakeWaiters();
        }

        // Suspend until signaled
        while (!waiter.signaled) {
            coro.xsuspend();
        }
    }

    fn wakeWaiters(self: *WaitGroup) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Mark all waiters as signaled and resume them
        for (self.waiters.items) |waiter| {
            waiter.signaled = true;
            coro.xresume(waiter.frame);
        }

        // Clear the waiters list
        self.waiters.clearRetainingCapacity();
    }
};
