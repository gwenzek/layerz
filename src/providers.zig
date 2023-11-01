const std = @import("std");
const io = std.io;
const layerz = @import("layerz.zig");
const InputEvent = layerz.InputEvent;
const log = std.log.scoped(.device);
const assert = std.debug.assert;

pub const c = layerz.linux;

pub const FileProvider = struct {
    infile: std.fs.File,
    outfile: std.fs.File,

    pub fn fromStdIO() FileProvider {
        return .{
            .infile = io.getStdIn(),
            .outfile = io.getStdOut(),
        };
    }

    pub fn deinit(self: *FileProvider) void {
        self.infile.close();
        self.outfile.close();
    }

    pub fn write_event(self: *FileProvider, event: InputEvent) void {
        write_event_to_file(self.outfile, event);
    }

    pub fn read_event(self: *FileProvider, timeout_ms: u32) ?InputEvent {
        // TODO: handle timeout
        // TODO: use tigerbeetle_io to read using io_uring
        _ = timeout_ms;
        var input: InputEvent = undefined;
        const buffer = std.mem.asBytes(&input);
        if (self.infile.read(buffer)) |bytes_read| {
            if (bytes_read == 0) return null;
            return input;
        } else |err| {
            std.debug.panic("Couldn't read event from infile: {}", .{err});
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
    _ = out.write(buffer) catch std.debug.panic("Couldn't write event {s} to outfile", .{event});
}

const EAGAIN: c_int = 11;

/// Uses libevdev to read the keyboard events. Writes to outfile.
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
/// And it's not really robust, because a key press/release can still be dropped altogether.
// TODO: should we ship libevdev and compile it ourselves ?
pub const EvdevProvider = struct {
    input: std.fs.File,
    outfile: std.fs.File,
    device: *c.libevdev,
    out: *c.libevdev_uinput,

    pub fn init(name: [:0]const u8) !EvdevProvider {
        const file = try std.fs.openFileAbsoluteZ(name, .{ .mode = .read_only });
        var dev: ?*c.libevdev = undefined;
        var rc = c.libevdev_new_from_fd(file.handle, &dev);
        if (rc < 0 or dev == null) {
            return error.NoDevice;
        }
        // Grab the device, this prevents other clients
        // (including kernel-internal ones such as rfkill) from receiving events from this device.
        // It is required to read from the device with a low latency.
        // Without that typing is very sluggish, I'm not sure why.
        // TODO: delay grabbing to first press to allow releases that happened before to propagate
        rc = c.libevdev_grab(dev, c.LIBEVDEV_GRAB);
        if (rc < 0) {
            log.err("Device {s} is already owned by another process !", .{name});
            return error.SharingViolation;
        }
        // Release and re-grab, this prevent accidentally disabling the trackpad.
        // I don't understand why this help, but I'm not the only one with this issue
        // https://github.com/ItayGarin/ktrl/blob/55f7697d34e96376cd327860bbb55450b2d11953/src/kbd_in.rs#L20
        _ = c.libevdev_grab(dev, c.LIBEVDEV_UNGRAB);
        _ = c.libevdev_grab(dev, c.LIBEVDEV_GRAB);
        log.debug("libedev reading from device at {s}", .{name});
        const out_dev = try allocOutputDevice(dev.?);
        const out_handle = c.libevdev_uinput_get_fd(out_dev);
        log.debug("libedev writing to {}", .{out_handle});

        const self = EvdevProvider{
            .device = dev.?,
            .input = file,
            .outfile = std.fs.File{ .handle = out_handle },
            .out = out_dev,
        };
        return self;
    }

    pub fn deinit(self: *EvdevProvider) void {
        _ = c.libevdev_grab(self.device, c.LIBEVDEV_UNGRAB);
        _ = c.libevdev_free(self.device);
        _ = c.libevdev_uinput_destroy(self.out);
        // outfile will be closed by libevdev
        self.input.close();
    }

    pub fn write_event(self: *EvdevProvider, event: InputEvent) void {
        check(c.libevdev_uinput_write_event(self.out, event.type, event.code, event.value));
        // write_event_to_file(self.outfile, event);
        // var ev2 = event;
        // ev2.type = c.EV_SND;
        // ev2.code = c.SND_CLICK;
        // ev2.value = 0;
        // write_event_to_file(self.outfile, ev2);
    }

    pub fn read_event(self: *EvdevProvider, timeout_ms: u32) ?InputEvent {
        _ = timeout_ms;
        var input: c.input_event = undefined;
        // Adapted from intercept.c: https://gitlab.com/interception/linux/tools/-/blob/master/intercept.c#L59
        const READ_BLOCKING = c.LIBEVDEV_READ_FLAG_NORMAL | c.LIBEVDEV_READ_FLAG_BLOCKING;
        while (true) {
            var rc = c.libevdev_next_event(self.device, READ_BLOCKING, &input);
            while (rc == c.LIBEVDEV_READ_STATUS_SYNC) {
                rc = c.libevdev_next_event(self.device, c.LIBEVDEV_READ_FLAG_SYNC, &input);
            }

            if (rc == -EAGAIN)
                // No event available.
                // TODO: handle timeout
                continue;

            if (rc != c.LIBEVDEV_READ_STATUS_SUCCESS)
                std.debug.panic("Couldn't read event from device: {}", .{rc});

            // Kind of ugly, the main reason I'm creating my own struct is to have
            // nice formatting. Maybe there is a better way.
            return @as(InputEvent, @bitCast(input));
        }
    }
};

fn allocOutputDevice(input: *const c.libevdev) !*c.libevdev_uinput {
    const out = c.libevdev_new();
    if (out == null) return error.OutOfMemory;
    const output = out.?;

    copyAttr("name", input, output);
    copyAttr("phys", input, output);
    copyAttr("uniq", input, output);
    copyAttr("id_product", input, output);
    copyAttr("id_vendor", input, output);
    copyAttr("id_bustype", input, output);
    // copyAttr("driver_version", input, output); // not read in uinput

    _ = c.libevdev_enable_property(output, c.INPUT_PROP_POINTER);
    // TODO: copy all props at once
    copyProp(c.INPUT_PROP_DIRECT, input, output);
    copyProp(c.INPUT_PROP_BUTTONPAD, input, output);
    copyProp(c.INPUT_PROP_SEMI_MT, input, output);
    copyProp(c.INPUT_PROP_TOPBUTTONPAD, input, output);
    copyProp(c.INPUT_PROP_POINTING_STICK, input, output);
    copyProp(c.INPUT_PROP_ACCELEROMETER, input, output);

    enableEvents(input, output);

    var uiout: ?*c.libevdev_uinput = undefined;
    var rc = c.libevdev_uinput_create_from_device(output, c.LIBEVDEV_UINPUT_OPEN_MANAGED, &uiout);
    if (rc < 0) return error.UinputError;

    return uiout.?;
}

inline fn copyAttr(
    comptime attr_name: [:0]const u8,
    input: *const c.libevdev,
    output: *c.libevdev,
) void {
    var attr = @field(c, "libevdev_get_" ++ attr_name)(input);
    @field(c, "libevdev_set_" ++ attr_name)(output, attr);
}

fn copyProp(
    property: c_uint,
    input: *const c.libevdev,
    output: *c.libevdev,
) void {
    if (c.libevdev_has_property(input, property) == 1) {
        std.debug.assert(c.libevdev_enable_property(output, property) == 0);
    }
}

/// TODO: here I'm just copying code from "uinput.cpp"
/// I'm not sure why we need to enable those events,
/// it seems to work fine without eg enabling keys.
/// And this code seems to also sometimes disable the trackpad on launch.
fn enableEvents(
    input: *const c.libevdev,
    output: *c.libevdev,
) void {
    check(c.libevdev_enable_event_type(output, c.EV_SYN));
    check(c.libevdev_enable_event_type(output, c.EV_KEY));
    check(c.libevdev_enable_event_type(output, c.EV_REL));
    check(c.libevdev_enable_event_type(output, c.EV_ABS));
    check(c.libevdev_enable_event_type(output, c.EV_MSC));
    check(c.libevdev_enable_event_type(output, c.EV_SW));
    check(c.libevdev_enable_event_type(output, c.EV_LED));
    check(c.libevdev_enable_event_type(output, c.EV_SND));
    check(c.libevdev_enable_event_type(output, c.EV_REP));

    var syn_code: c_uint = 0;
    while (syn_code <= c.SYN_DROPPED) : (syn_code += 1) {
        check(c.libevdev_enable_event_code(output, c.EV_SYN, syn_code, null));
    }

    // TODO: directly set output.key_bits to 1, ... 1
    // This requires importing libevdev-int.h
    var key_code: c_uint = 0;
    while (key_code < c.KEY_MAX) : (key_code += 1) {
        check(c.libevdev_enable_event_code(output, c.EV_KEY, key_code, null));
    }

    var mouse_code: c_uint = 0;
    while (mouse_code < c.REL_MAX) : (mouse_code += 1) {
        check(c.libevdev_enable_event_code(output, c.EV_REL, mouse_code, null));
    }

    var delay: c_int = undefined;
    var period: c_int = undefined;
    check(c.libevdev_get_repeat(input, &delay, &period));
    check(c.libevdev_enable_event_code(output, c.EV_REP, c.REP_DELAY, &delay));
    check(c.libevdev_enable_event_code(output, c.EV_REP, c.REP_PERIOD, &period));
}

fn check(errno: c_int) void {
    assert(errno == 0);
}
