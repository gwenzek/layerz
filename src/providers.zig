const std = @import("std");
const io = std.io;
const layerz = @import("layerz.zig");
const InputEvent = layerz.InputEvent;
const log = std.log.scoped(.device);

pub const evdev = layerz.linux;

pub const StdIoProvider = struct {
    stdin: std.fs.File,
    stdout: std.fs.File,

    pub fn init() StdIoProvider {
        return .{
            .stdin = io.getStdIn(),
            .stdout = io.getStdOut(),
        };
    }

    pub fn deinit(self: *StdIoProvider) void {
        _ = self;
    }

    pub fn write_event(self: *StdIoProvider, event: InputEvent) void {
        write_event_to_file(self.stdout, event);
    }

    pub fn read_event(self: *StdIoProvider, timeout_ms: u32) ?InputEvent {
        // TODO: handle timeout
        // TODO: use tigerbeetle_io to read using io_uring
        _ = timeout_ms;
        var input: InputEvent = undefined;
        const buffer = std.mem.asBytes(&input);
        if (self.stdin.read(buffer)) |bytes_read| {
            if (bytes_read == 0) return null;
            return input;
        } else |err| {
            std.debug.panic("Couldn't read event from stdin: {}", .{err});
        }
    }
};

fn write_event_to_file(out: anytype, event: InputEvent) void {
    const buffer = std.mem.asBytes(&event);
    log.debug("wrote {}", .{event});
    // if (event.code == layerz.resolve("CAPSLOCK")) {
    //     log.warn("!!! writing CAPSLOCK !!!", .{});
    //     std.debug.panic("CAPSLOCK shouldn't be emitted", .{});
    // }
    // TODO: use io uring ?
    // currently we need a syscall to write a single event
    _ = out.write(buffer) catch std.debug.panic("Couldn't write event {s} to stdout", .{event});
}

const EAGAIN: c_int = 11;

/// Uses libevdev to read the keyboard events. Writes to stdout.
/// https://www.freedesktop.org/wiki/Software/libevdev/
/// evdev is doing the following for us:
///  - maintains the state of each key (pressed or released)
///  - maintains a queue of events, and try to prefetch events
///  - if the buffer of events overflow (ie we receive SYN_DROPPED),
///    will fetch the keyboard state and compare with internal state
///    and emit the "diff" events.
/// This seems in part redundant with what layerz does, because we also need to
/// keep track of the keyboard state, but also it's more complicated logic.
/// Also I'm not sure if this feature is very useful for keyboard input, are
/// you continuing to write tonne of prose while your laptop is frozen ?
// TODO: should we ship libevdev and compile it ourselves ?
pub const EvdevProvider = struct {
    input: std.fs.File,
    stdout: std.fs.File,
    device: *evdev.libevdev,

    pub fn init(name: [:0]const u8) !EvdevProvider {
        const file = try std.fs.openFileAbsoluteZ(name, .{ .read = true });
        var dev: ?*evdev.libevdev = undefined;
        var rc = evdev.libevdev_new_from_fd(file.handle, &dev);
        if (rc < 0 or dev == null) {
            return error.NoDevice;
        }
        // Grab the device, this prevents other clients
        // (including kernel-internal ones such as rfkill) from receiving events from this device.
        // It is required to read from the device with a low latency.
        // Without that typing is very sluggish, I'm not sure why.
        // TODO: delay grabbing to first press to allow releases that happened before to propagate
        rc = evdev.libevdev_grab(dev, evdev.LIBEVDEV_GRAB);
        if (rc < 0) {
            return error.SharingViolation;
        }
        log.debug("libedev reading from device at {s} ({*})", .{ name, dev });

        return EvdevProvider{
            .device = dev.?,
            .input = file,
            .stdout = io.getStdOut(),
        };
    }

    pub fn deinit(self: *EvdevProvider) void {
        _ = evdev.libevdev_grab(self.device, evdev.LIBEVDEV_UNGRAB);
        _ = evdev.libevdev_free(self.device);
        self.input.close();
    }

    pub fn write_event(self: *EvdevProvider, event: InputEvent) void {
        write_event_to_file(self.stdout, event);
    }

    pub fn read_event(self: *EvdevProvider, timeout_ms: u32) ?InputEvent {
        _ = timeout_ms;
        var input: evdev.input_event = undefined;
        // Adapted from intercept.c: https://gitlab.com/interception/linux/tools/-/blob/master/intercept.c#L59
        const READ_BLOCKING = evdev.LIBEVDEV_READ_FLAG_NORMAL | evdev.LIBEVDEV_READ_FLAG_BLOCKING;
        while (true) {
            var rc = evdev.libevdev_next_event(self.device, READ_BLOCKING, &input);
            while (rc == evdev.LIBEVDEV_READ_STATUS_SYNC) {
                rc = evdev.libevdev_next_event(self.device, evdev.LIBEVDEV_READ_FLAG_SYNC, &input);
            }

            if (rc == -EAGAIN)
                // No event available.
                // TODO: handle timeout
                continue;

            if (rc != evdev.LIBEVDEV_READ_STATUS_SUCCESS)
                std.debug.panic("Couldn't read event from device: {}", .{rc});

            // Kind of ugly, the main reason I'm creating my own struct is to have
            // nice formatting. Maybe there is a better way.
            return @bitCast(InputEvent, input);
        }
    }
};
