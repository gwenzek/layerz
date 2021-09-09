const std = @import("std");
const layerz = @import("layerz.zig");

usingnamespace layerz;

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = &general_purpose_allocator.allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    std.log.info("All your codebase are belong to us.", .{});

    // Here you can describe your different layers.
    var azerty = PASSTHROUGH;
    map(&azerty, "Q", k("A"));
    map(&azerty, "W", k("Z"));
    map(&azerty, "A", k("Q"));
    map(&azerty, "Z", k("W"));
    map(&azerty, "S", s("9"));
    const layout = [_]Layerz{azerty};
    var keyboard = KeyboardState{ .layout = &layout };
    keyboard.init();
    keyboard.loop();
}
