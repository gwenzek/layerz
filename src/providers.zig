const std = @import("std");
const io = std.io;
const layerz = @import("layerz.zig");
const InputEvent = layerz.InputEvent;
const log = std.log.scoped(.device);

pub const c = layerz.linux;

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
    device: *c.libevdev,
    out: *c.libevdev_uinput,

    pub fn init(name: [:0]const u8) !EvdevProvider {
        const file = try std.fs.openFileAbsoluteZ(name, .{ .read = true });
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
        log.debug("libedev reading from device at {s}", .{name});

        const out_dev = try allocOutputDevice(dev.?);
        const self = EvdevProvider{
            .device = dev.?,
            .input = file,
            .stdout = std.fs.File{ .handle = c.libevdev_uinput_get_fd(out_dev) },
            .out = out_dev,
        };
        self.beep();
        return self;
    }

    pub fn deinit(self: *EvdevProvider) void {
        _ = c.libevdev_grab(self.device, c.LIBEVDEV_UNGRAB);
        _ = c.libevdev_free(self.device);
        _ = c.libevdev_uinput_destroy(self.out);
        // stdout will be closed by libevdev
        self.input.close();
    }

    pub fn write_event(self: *EvdevProvider, event: InputEvent) void {
        write_event_to_file(self.stdout, event);
        // var ev2 = event;
        // ev2.type = c.EV_SND;
        // ev2.code = c.SND_CLICK;
        // ev2.value = 0;
        // write_event_to_file(self.stdout, ev2);
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
            return @bitCast(InputEvent, input);
        }
    }

    pub fn beep(self: *const EvdevProvider) void {
        // Write a bell char to the tty.
        // Normally I should be able to use ioctl to write EV_SND to the device
        // but haven't managed to do so yet.
        _ = self;
        const console = std.fs.openFileAbsoluteZ("/dev/tty", .{ .write = true }) catch return;
        _ = console.writer().writeByte(7) catch return;
    }
};

fn allocOutputDevice(input: *const c.libevdev) !*c.libevdev_uinput {
    const out = c.libevdev_new();
    if (out == null) return error.NoDevice;
    const output = out.?;

    copyAttr("name", input, output);
    copyAttr("phys", input, output);
    copyAttr("uniq", input, output);
    copyAttr("id_product", input, output);
    copyAttr("id_vendor", input, output);
    copyAttr("id_bustype", input, output);
    // copyAttr("driver_version", input, output);  // not read in uinput

    copyProp(c.INPUT_PROP_POINTER, input, output);
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

fn enableEvents(
    input: *const c.libevdev,
    output: *c.libevdev,
) void {
    _ = input;
    _ = output;

    var syn_code: c_uint = 0;
    while (syn_code <= c.SYN_DROPPED) : (syn_code += 1) {
        _ = c.libevdev_enable_event_code(output, c.EV_SYN, syn_code, null);
    }

    var key_code: c_uint = 0;
    while (key_code < c.KEY_MAX) : (key_code += 1) {
        _ = c.libevdev_enable_event_code(output, c.EV_KEY, key_code, null);
    }

    var sound_code: c_uint = 0;
    while (sound_code <= c.SND_TONE) : (sound_code += 1) {
        _ = c.libevdev_enable_event_code(output, c.EV_SND, sound_code, null);
    }

    var delay: c_int = undefined;
    var period: c_int = undefined;
    _ = c.libevdev_get_repeat(input, &delay, &period);
    _ = c.libevdev_enable_event_code(output, c.EV_REP, c.REP_DELAY, &delay);
    _ = c.libevdev_enable_event_code(output, c.EV_REP, c.REP_PERIOD, &period);

    // TODO: enable mouse events (EV_REL)
}

//             for (const auto &event_type : event_types) {
//                 auto event_type_string = event_type.first.as<string>();
//                 else if (event_type_string == "EV_ABS") {
//                     for (const auto &axis : event_type.second) {
//                         input_absinfo absinfo = {};
//                         if (auto axis_value = axis.second["VALUE"])
//                             absinfo.value = axis_value.as<int>();
//                         if (auto axis_min = axis.second["MIN"])
//                             absinfo.minimum = axis_min.as<int>();
//                         if (auto axis_max = axis.second["MAX"])
//                             absinfo.maximum = axis_max.as<int>();
//                         if (auto axis_flat = axis.second["FLAT"])
//                             absinfo.flat = axis_flat.as<int>();
//                         if (auto fuzz = axis.second["FUZZ"])
//                             absinfo.fuzz = fuzz.as<int>();
//                         if (auto res = axis.second["RES"])
//                             absinfo.resolution = res.as<int>();

//                         if (!axis.second["VALUE"] && axis.second["MAX"])
//                             absinfo.value = absinfo.maximum;
//                         if (!axis.second["VALUE"] && axis.second["MIN"])
//                             absinfo.value = absinfo.minimum;

//                         auto axis_code = libevdev_event_code_from_name(
//                             EV_ABS, axis.first.as<string>().c_str());
//                         if (axis_code != -1)
//                             libevdev_enable_event_code(dev, EV_ABS, axis_code,
//                                                        &absinfo);
//                     }
//                 } else {
//                     auto event_type_code = libevdev_event_type_from_name(
//                         event_type_string.c_str());

//                     for (const auto &event : event_type.second) {
//                         auto event_string = event.as<string>();
//                         if (is_int(event_string))
//                             libevdev_enable_event_code(dev, event_type_code,
//                                                        stoi(event_string),
//                                                        nullptr);
//                         else {
//                             auto event_code = libevdev_event_code_from_name(
//                                 event_type_code, event_string.c_str());
//                             if (event_code != -1)
//                                 libevdev_enable_event_code(dev, event_type_code,
//                                                            event_code, nullptr);
//                         }
//                     }
//                 }
//             }
//         }
//     }
//     return dev;
// }
