const std = @import("std");
const layerz = @import("layerz.zig");
const InputEvent = layerz.InputEvent;

fn count_latency(n: i32) !void {
    var total_latency: i128 = 0;
    var total_events: i32 = 0;
    var event: InputEvent = undefined;
    const buffer = std.mem.asBytes(&event);
    while (std.io.getStdIn().read(buffer)) {
        total_latency += latency(event);
        total_events += 1;
        if (total_events > n) {
            break;
        }
    } else |err| {
        std.debug.panic("Couldn't read event from stdin", .{});
    }
    var avg_latency = @intToFloat(f64, total_latency) / @intToFloat(f64, total_events) / std.time.ns_per_ms;
    var out = std.io.getStdOut().writer();
    try std.fmt.format(out, "Recorded {} events. Avg latency = {d:.3} ms\n", .{ total_events, avg_latency });
}

fn latency(event: InputEvent) i128 {
    const time_ns: i128 = std.time.nanoTimestamp();
    const event_time_ns: i128 = event.time.tv_sec * std.time.ns_per_s + event.time.tv_usec * std.time.ns_per_us;
    return time_ns - event_time_ns;
}

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = &general_purpose_allocator.allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    var n: i32 = 50;
    std.log.info("Computing latency of the next {} key presses", .{n});

    try count_latency(n);
}
