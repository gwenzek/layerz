const std = @import("std");
const layerz = @import("layerz.zig");

usingnamespace layerz;

const mod_layer = ansi(
    .{ __, k("F1"), k("F2"), k("F3"), k("F4"), k("F5"), k("F6"), k("F7"), k("F8"), k("F9"), k("F10"), k("F11"), k("F12") },
    .{ __, k("1"), k("2"), k("3"), k("4"), k("5"), k("6"), k("7"), k("8"), k("9"), k("0"), k("BACKSLASH"), xx, xx },
    .{ __, k("LEFTBRACE"), s("9"), s("0"), k("RIGHTBRACE"), k("SPACE"), k("BACKSPACE"), k("LEFT"), k("UP"), k("DOWN"), k("RIGHT"), s("APOSTROPHE"), __ },
    .{ __, s("EQUAL"), s("MINUS"), k("MINUS"), k("EQUAL"), s("GRAVE"), k("ESC"), k("HOME"), k("PAGEUP"), k("PAGEDOWN"), k("END"), __ },
);

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = &general_purpose_allocator.allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    std.log.info("All your codebase are belong to us.", .{});

    // Here you can describe your different layers.
    var layer = PASSTHROUGH;
    map(&layer, "SPACE", lh("SPACE", 1));
    map(&layer, "LEFTSHIFT", k("LEFTMETA"));
    map(&layer, "LEFTALT", k("LEFTCTRL"));
    map(&layer, "CAPSLOCK", k("LEFTSHIFT"));

    var keyboard = KeyboardState{ .layout = &[_]Layer{ layer, mod_layer } };
    keyboard.init();
    keyboard.loop();
}
