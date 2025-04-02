const std = @import("std");
const http = std.http;

const xev = @import("xev");
const zo = @import("zo");
const aio = zo.asyncio;

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
        .default_stack_size = 1024 * 4,
    });

    try aio.run(executor, mainTask, .{}, null);
}

fn mainTask() !void {
    const t1 = try zo.xasync(task, .{ "Task-1", 5 }, null);
    const t2 = try zo.xasync(task, .{ "Task-2", 1 }, null);
    const t3 = try zo.xasync(task, .{ "Task-3", 3 }, null);

    defer {
        t1.deinit();
        t2.deinit();
        t3.deinit();
    }

    _ = try zo.xawait(t1);
    _ = try zo.xawait(t2);
    _ = try zo.xawait(t3);
}

fn task(name: []const u8, delay_ms: u64) !void {
    std.debug.print("{s} starting, will sleep for {}ms\n", .{ name, delay_ms });
    try aio.sleep(null, delay_ms);
    std.debug.print("{s} completed after {}ms\n", .{ name, delay_ms });
}
