const std = @import("std");
const layerz = @import("layerz.zig");
const InputEvent = layerz.InputEvent;

const stdout = std.io.getStdOut().writer();

fn count_latency(n: i32) !void {
    var total_latency: i128 = 0;
    var total_events: i32 = 0;
    var event: InputEvent = undefined;
    const buffer = std.mem.asBytes(&event);
    while (std.io.getStdIn().read(buffer)) {
        // only look at key events.
        if (event.type != layerz.linux.EV_KEY) continue;

        total_latency += latency(event);
        total_events += 1;
        if (total_events >= n) {
            break;
        }
    } else |err| {
        std.debug.panic("Couldn't read event from stdin", .{});
    }
    var avg_latency = @intToFloat(f64, total_latency) / @intToFloat(f64, total_events) / std.time.ns_per_ms;
    try std.fmt.format(stdout, "Recorded {} events. Avg latency = {d:.3} ms\n", .{ total_events, avg_latency });
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
    const n: i32 = if (args.len > 1) try std.fmt.parseInt(i32, args[1], 10) else 50;
    try std.fmt.format(stdout, "Computing latency of the next {} key presses\n", .{n});
    try count_latency(n);
}
