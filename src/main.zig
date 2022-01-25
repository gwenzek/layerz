const std = @import("std");
const l = @import("layerz.zig");
const log = std.log;

const m_up = l.LayerzAction{ .mouse_move = .{ .stepX = 10 } };
const m_down = l.LayerzAction{ .mouse_move = .{ .stepX = -10 } };
const m_left = l.LayerzAction{ .mouse_move = .{ .stepY = 10 } };
const m_right = l.LayerzAction{ .mouse_move = .{ .stepY = -10 } };

const k = l.k;
const s = l.s;
const __ = l.__;

const reset_usb = l.LayerzAction{ .hook = .{ .f = resetUsbDevices } };

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    std.log.info("All your codebase are belong to us.", .{});

    // Here you can describe your different layers.
    var layer = l.PASSTHROUGH;
    l.map(&layer, "SPACE", l.lh("SPACE", 1));
    l.map(&layer, "LEFTSHIFT", k("LEFTMETA"));
    l.map(&layer, "LEFTALT", k("LEFTCTRL"));
    l.map(&layer, "CAPSLOCK", k("LEFTSHIFT"));

    const mod_layer = l.ansi(
        .{ __, k("F1"), k("F2"), k("F3"), k("F4"), k("F5"), k("F6"), k("F7"), k("F8"), k("F9"), k("F10"), k("F11"), k("F12") },
        .{ __, k("1"), k("2"), k("3"), k("4"), k("5"), k("6"), k("7"), k("8"), k("9"), k("0"), k("BACKSLASH"), l.xx, reset_usb },
        .{ __, k("LEFTBRACE"), s("9"), s("0"), k("RIGHTBRACE"), k("SPACE"), k("BACKSPACE"), k("LEFT"), k("UP"), k("DOWN"), k("RIGHT"), s("APOSTROPHE"), __ },
        .{ __, s("EQUAL"), s("MINUS"), k("MINUS"), k("EQUAL"), s("GRAVE"), k("ESC"), k("HOME"), k("PAGEUP"), k("PAGEDOWN"), k("END"), __ },
    );

    // l.map(&layer, "UP", m_up);
    // l.map(&layer, "DOWN", m_down);
    // l.map(&layer, "RIGHT", m_right);
    // l.map(&layer, "LEFT", m_left);

    // TODO: use DeviceProvider or StdioProvider depending on the input args
    var keyboard = l.stdioKeyboard(&[_]l.Layer{ layer, mod_layer });
    defer keyboard.deinit();
    keyboard.loop();
}

fn resetUsbDevices() !void {
    const hub = "/dev/bus/usb/001";
    const devices = try std.fs.openDirAbsoluteZ(hub, .{ .iterate = true });
    var it = devices.iterate();
    while (try it.next()) |dev| {
        const id = try std.fmt.parseUnsigned(u8, dev.name, 10);
        if (id <= 10) continue;
        // Firsts ports are for built-in peripherals

        const dev_fs = try devices.openFile(dev.name, .{ .write = true });
        // Defined in linux kernel, in usbdevice_fs.h
        const USBDEVFS_RESET = std.os.linux.IOCTL.IO('U', 20);
        const rc = std.os.linux.ioctl(dev_fs.handle, USBDEVFS_RESET, 0);
        if (rc < 0) return error.Unknown;

        log.info("Resetted USB device {s}/{s}", .{ hub, dev.name });
    }
}
