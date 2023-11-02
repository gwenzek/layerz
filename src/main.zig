const std = @import("std");
const l = @import("layerz.zig");
const log = std.log;

// Moves the mouse by 20mm increments.
const m_step = 20;
const m_up = l.Action{ .mouse_move = .{ .stepY = -m_step } };
const m_down = l.Action{ .mouse_move = .{ .stepY = m_step } };
const m_right = l.Action{ .mouse_move = .{ .stepX = m_step } };
const m_left = l.Action{ .mouse_move = .{ .stepX = -m_step } };

const k = l.k;
const s = l.s;
const __ = l.__;

const reset_usb = l.Action{ .hook = .{ .f = resetUsbDevices } };
const beep = l.Action{ .hook = .{ .f = makeBeep } };

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    // Here you can describe your different layers.
    var layer = l.PASSTHROUGH;
    l.map(&layer, "SPACE", l.lh("SPACE", 1));
    l.map(&layer, "LEFTSHIFT", k("LEFTMETA"));
    l.map(&layer, "LEFTALT", k("LEFTCTRL"));
    l.map(&layer, "CAPSLOCK", k("LEFTSHIFT"));

    var mod_layer = l.ansi(
        .{ __, k("F1"), k("F2"), k("F3"), k("F4"), k("F5"), k("F6"), k("F7"), k("F8"), k("F9"), k("F10"), k("F11"), k("F12") },
        .{ __, k("1"), k("2"), k("3"), k("4"), k("5"), k("6"), k("7"), k("8"), k("9"), k("0"), k("BACKSLASH"), l.xx, reset_usb },
        .{ __, k("LEFTBRACE"), s("9"), s("0"), k("RIGHTBRACE"), k("SPACE"), k("BACKSPACE"), k("LEFT"), k("UP"), k("DOWN"), k("RIGHT"), s("APOSTROPHE"), __ },
        .{ __, s("EQUAL"), s("MINUS"), k("MINUS"), k("EQUAL"), s("GRAVE"), k("ESC"), k("HOME"), k("PAGEUP"), k("PAGEDOWN"), k("END"), __ },
    );

    l.map(&mod_layer, "UP", m_up);
    l.map(&mod_layer, "DOWN", m_down);
    l.map(&mod_layer, "RIGHT", m_right);
    l.map(&mod_layer, "LEFT", m_left);
    // could "beep" be useful for multi key combos ?
    // l.map(&mod_layer, "ESC", beep);

    if (args.len < 2) {
        log.info("Reading/writing keyboard events from stdin/out", .{});
        var keyboard = l.stdioKeyboard(&[_]l.Layer{ layer, mod_layer });
        defer keyboard.deinit();
        keyboard.loop();
    } else {
        log.info("Reading/writing keyboard events from {s}", .{args[1]});
        var keyboard = l.evdevKeyboard(&[_]l.Layer{ layer, mod_layer }, args[1]);
        // keyboard.keystrokes_limit = 100;
        defer keyboard.deinit();
        keyboard.loop();
    }
}

fn resetUsbDevices() !void {
    const hub = "/dev/bus/usb/001";
    var devices = try std.fs.openIterableDirAbsolute(hub, .{ .access_sub_paths = true });
    defer devices.close();
    var it = devices.iterate();
    while (try it.next()) |dev| {
        const id = try std.fmt.parseUnsigned(u8, dev.name, 10);
        if (id <= 10) continue;
        // Firsts ports are for built-in peripherals
        log.info("Reading/writing keyboard events from stdin/out", .{});

        const dev_fs = try devices.dir.openFile(dev.name, .{ .mode = .write_only });
        // const dev_fs = try devices.openFile(dev.name, .{ .write = true });
        // Defined in linux kernel, in usbdevice_fs.h
        const USBDEVFS_RESET = std.os.linux.IOCTL.IO('U', 20);
        const rc = std.os.linux.ioctl(dev_fs.handle, USBDEVFS_RESET, 0);
        if (rc < 0) return error.Unknown;

        log.info("Resetted USB device {s}/{s}", .{ hub, dev.name });
    }
}

pub fn makeBeep() !void {
    // Write a bell char to the tty.
    // Normally I should be able to use ioctl to write EV_SND to the device
    // but haven't managed to do so yet.
    const console = std.fs.openFileAbsoluteZ("/dev/tty", .{ .write = true }) catch return;
    _ = console.writer().writeByte(7) catch return;
}
