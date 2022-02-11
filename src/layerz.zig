/// Reference https://www.kernel.org/doc/html/v4.15/input/event-codes.html
const std = @import("std");
const testing = std.testing;
const math = std.math;
const log = std.log.scoped(.layerz);
pub const linux = @cImport({
    @cInclude("linux/input.h");
    @cInclude("libevdev.h");
    @cInclude("libevdev-uinput.h");
});

const providers = @import("providers.zig");
const KeyboardState = @import("handler.zig").KeyboardState;

pub var _start_time: i64 = -1;

/// This is a port of linux input_event struct.
/// Linux kernel has different way of storing the time depending on the architecture
/// this isn't currently supported in Layerz code (notably in `delta_ms`)
pub const InputEvent = extern struct {
    time: linux.timeval,
    type: u16,
    code: u16,
    value: i32,

    pub fn format(
        input: *const InputEvent,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        // use time relative to the start of the program
        const time: f64 = math.lossyCast(f64, input.time.tv_sec - _start_time) + math.lossyCast(f64, input.time.tv_usec) / std.time.us_per_s;
        if (input.type == linux.EV_KEY) {
            const value = switch (input.value) {
                KEY_PRESS => "KEY_PRESS",
                KEY_RELEASE => "KEY_RELEASE",
                KEY_REPEAT => "KEY_REPEAT",
                else => {
                    try std.fmt.format(writer, "{{ EV_KEY({x}, {x}) ({d:.3}) }}", .{ input.value, input.code, time });
                    return;
                },
            };
            try std.fmt.format(writer, "{{{s}({s}) ({d:.3})}}", .{ value, resolveName(input.code), time });
        } else {
            const ev_type = switch (input.type) {
                linux.EV_REL => "EV_REL",
                linux.EV_SYN => "EV_SYN",
                linux.EV_ABS => "EV_ABS",
                linux.EV_MSC => "EV_MSC",
                else => {
                    try std.fmt.format(writer, "{{EV({x})({x}, {d}) ({d:.3})}}", .{ input.type, input.code, input.value, time });
                    return;
                },
            };
            try std.fmt.format(writer, "{{{s}({x}, {d}) ({d:.3})}}", .{ ev_type, input.code, input.value, time });
        }
    }
};

test "InputEvent matches input_event byte by byte" {
    const c_struct = linux.input_event{
        .type = linux.EV_KEY,
        .value = KEY_PRESS,
        .code = 88,
        .time = .{ .tv_sec = 123, .tv_usec = 456789 },
    };
    const zig_struct = InputEvent{
        .type = linux.EV_KEY,
        .value = KEY_PRESS,
        .code = 88,
        .time = .{ .tv_sec = 123, .tv_usec = 456789 },
    };

    try testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&c_struct),
        std.mem.asBytes(&zig_struct),
    );
}

// Those values are documented in linux doc:
// https://www.kernel.org/doc/html/v4.15/input/event-codes.html#ev-key
pub const KEY_PRESS = 1;
pub const KEY_RELEASE = 0;
pub const KEY_REPEAT = 2;

const ActionKind = enum {
    tap,
    mod_tap,
    layer_hold,
    layer_toggle,
    disabled,
    transparent,
    mouse_move,
    hook,
};

pub const Action = union(ActionKind) {
    tap: Tap,
    mod_tap: ModTap,
    layer_hold: LayerHold,
    layer_toggle: LayerToggle,
    disabled: Disabled,
    transparent: Transparent,
    mouse_move: MouseMove,
    hook: Hook,

    pub const Tap = struct { key: u8 };
    pub const ModTap = struct { key: u8, mod: u8 };
    pub const LayerHold = struct { key: u8, layer: u8, delay_ms: u16 = 200 };
    pub const LayerToggle = struct { layer: u8 };
    pub const Disabled = struct {};
    pub const Transparent = struct {};
    pub const Hook = struct { f: fn () anyerror!void };
    pub const MouseMove = struct {
        key: u8 = linux.REL_X,
        /// Moves the mouse right (in millimeters)
        stepX: i16 = 0,
        /// Moves the mouse down (in millimeters)
        stepY: i16 = 0,
    };
};

pub const NUM_KEYS = 256;
pub const Layer = [NUM_KEYS]Action;

pub fn resolve(comptime keyname: []const u8) u8 {
    const fullname = "KEY_" ++ keyname;
    if (!@hasDecl(linux, fullname)) {
        @compileError("input-event-codes.h doesn't declare: " ++ fullname);
    }
    return @field(linux, fullname);
}

const _keynames = [_][]const u8{ "ESC", "TAB", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "ENTER", "LCTRL", "A", "S", "D", "F", "G", "H" };
const _first_key_index = @as(u16, resolve(_keynames[0]));

pub fn resolveName(keycode: u16) []const u8 {
    if (keycode < _first_key_index) return "LOW";
    var offset = keycode - _first_key_index;
    if (offset >= _keynames.len) return "HIGH";
    return _keynames[offset];
}

test "Resolve keyname" {
    try testing.expectEqual(linux.KEY_Q, resolve("Q"));
    try testing.expectEqual(linux.KEY_TAB, resolve("TAB"));
    try testing.expectEqual(linux.KEY_LEFTSHIFT, resolve("LEFTSHIFT"));
}

/// Layout DSL: tap the given key
pub fn k(comptime keyname: []const u8) Action {
    return .{ .tap = .{ .key = resolve(keyname) } };
}

/// Layout DSL: tap shift and the given key
pub fn s(comptime keyname: []const u8) Action {
    return .{
        .mod_tap = .{ .key = resolve(keyname), .mod = linux.KEY_LEFTSHIFT },
    };
}

/// Layout DSL: tap ctrl and the given key
pub fn ctrl(comptime keyname: []const u8) Action {
    return .{
        .mod_tap = .{ .key = resolve(keyname), .mod = linux.KEY_LEFTCTRL },
    };
}

/// Layout DSL: tap altgr (right alt) and the given key. Useful for inputing localized chars.
pub fn altgr(comptime keyname: []const u8) Action {
    return .{
        .mod_tap = .{ .key = resolve(keyname), .mod = linux.KEY_RIGHTALT },
    };
}

/// Layout DSL: toggle a layer
pub fn lt(layer: u8) Action {
    return .{
        .layer_toggle = .{ .layer = layer },
    };
}

/// Layout DSL: toggle a layer when hold, tap a key when tapped
pub fn lh(comptime keyname: []const u8, layer: u8) Action {
    return .{
        .layer_hold = .{ .layer = layer, .key = resolve(keyname) },
    };
}

/// Layout DSL: disable a key
pub const xx: Action = .{ .disabled = .{} };

/// Layout DSL: pass the key to the layer below
pub const __: Action = .{ .transparent = .{} };

pub const PASSTHROUGH: Layer = [_]Action{__} ** NUM_KEYS;

pub fn map(layer: *Layer, comptime src_key: []const u8, action: Action) void {
    layer[resolve(src_key)] = action;
}

/// From kernel docs:
/// Used to synchronize and separate events into packets of input data changes
/// occurring at the same moment in time.
/// For example, motion of a mouse may set the REL_X and REL_Y values for one motion,
/// then emit a SYN_REPORT.
/// The next motion will emit more REL_X and REL_Y values and send another SYN_REPORT.
pub const sync_report = InputEvent{
    .type = linux.EV_SYN,
    .code = linux.SYN_REPORT,
    .value = 0,
    .time = undefined,
};

/// From kernel docs:
/// Used to indicate buffer overrun in the evdev client’s event queue.
/// Client should ignore all events up to and including next SYN_REPORT event
/// and query the device (using EVIOCG* ioctls) to obtain its current state.
const sync_dropped = InputEvent{
    .type = linux.EV_SYN,
    .code = linux.SYN_DROPPED,
    .value = 0,
    .time = undefined,
};

pub var _special_release_enter: InputEvent = undefined;

pub const TestProvider = struct {
    outputs: std.ArrayList(InputEvent),
    inputs: []const InputEvent,
    time_ms: i64,
    offset: u16 = 0,

    fn init(inputs: []const InputEvent) TestProvider {
        // we are using fake timestamp for testing.
        _start_time = 0;
        return .{
            .inputs = inputs,
            .outputs = std.ArrayList(InputEvent).init(testing.allocator),
            .time_ms = _start_time,
        };
    }

    pub fn deinit(self: *TestProvider) void {
        self.outputs.deinit();
    }

    pub fn write_event(self: *TestProvider, event: InputEvent) void {
        // Skip the
        if (self.outputs.items.len == 0) {
            if (std.mem.eql(u8, std.mem.asBytes(&event), std.mem.asBytes(&sync_report)) or
                std.mem.eql(u8, std.mem.asBytes(&event), std.mem.asBytes(&_special_release_enter)))
                return;
        }
        self.outputs.append(event) catch unreachable;
        log.debug("wrote {}", .{event});
    }

    pub fn read_event(self: *TestProvider, timeout_ms: u32) ?InputEvent {
        if (self.offset >= self.inputs.len) return null;
        const event = self.inputs[self.offset];
        const event_ms = event.time.tv_sec * 1000 + @divFloor(event.time.tv_usec, 1000);
        if (timeout_ms > 0 and event_ms > self.time_ms + timeout_ms) {
            log.debug("Timed out after {}ms. Current time {}ms, next event: {}ms", .{ timeout_ms, self.time_ms, event_ms });
            self.time_ms += timeout_ms;
            return null;
        } else {
            self.time_ms = event_ms;
            self.offset += 1;
            return event;
        }
    }
};

pub fn testKeyboardAlloc(layout: []const Layer, events: []const InputEvent) KeyboardState(TestProvider) {
    const provider = TestProvider.init(events);
    var keeb = KeyboardState(TestProvider){
        .layout = layout,
        .event_provider = provider,
    };
    keeb.init();
    _start_time = 0;
    return keeb;
}

pub fn evdevKeyboard(layout: []const Layer, name: [:0]const u8) KeyboardState(providers.EvdevProvider) {
    const provider = providers.EvdevProvider.init(name) catch |err| std.debug.panic("can't open device {s} {}", .{ name, err });
    var keeb = KeyboardState(providers.EvdevProvider){
        .layout = layout,
        .event_provider = provider,
    };
    keeb.init();
    return keeb;
}

pub fn stdioKeyboard(layout: []const Layer) KeyboardState(providers.StdIoProvider) {
    const provider = providers.StdIoProvider.init();
    var keeb = KeyboardState(providers.StdIoProvider){
        .layout = layout,
        .event_provider = provider,
    };
    keeb.init();
    return keeb;
}

pub fn delta_ms(event1: InputEvent, event2: InputEvent) i32 {
    var delta = 1000 * (event2.time.tv_sec - event1.time.tv_sec);

    var delta_us = event2.time.tv_usec - event1.time.tv_usec;
    // Just be consistent on how the rounding is done.
    if (delta_us >= 0) {
        delta += @divFloor(delta_us, 1000);
    } else {
        delta -= @divFloor(-delta_us, 1000);
    }
    return math.lossyCast(i32, delta);
}

test "testKeyboard handle timeouts correctly" {
    var layer: Layer = PASSTHROUGH;
    const inputs = [_]InputEvent{
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_RELEASE, "Q", 0.1),
        input_event(KEY_PRESS, "Q", 0.5),
        input_event(KEY_RELEASE, "Q", 0.6),
    };
    var keyboard = testKeyboardAlloc(&.{layer}, &inputs);
    defer keyboard.deinit();

    try testing.expectEqual(keyboard.read_event(0), input_event(KEY_PRESS, "Q", 0.0));
    try testing.expectEqual(keyboard.read_event(5), null);
    try testing.expectEqual(keyboard.read_event(600), input_event(KEY_RELEASE, "Q", 0.1));
    try testing.expectEqual(keyboard.read_event(200), null);
    try testing.expectEqual(keyboard.read_event(0), input_event(KEY_PRESS, "Q", 0.5));
    // try testing.expectEqual(keyboard.read_event(100), input_event(KEY_PRESS, "Q", 0.1));
}

test "Key remap with modifier" {
    var layer: Layer = PASSTHROUGH;
    // Map "Q" to "(" (shift+9)
    map(&layer, "Q", s("9"));

    const inputs = [_]InputEvent{
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_RELEASE, "Q", 0.1),
    };
    var keyboard = testKeyboardAlloc(&.{layer}, &inputs);
    defer keyboard.deinit();
    keyboard.loop();

    const expected = [_]InputEvent{
        input_event(KEY_PRESS, "LEFTSHIFT", 0.0),
        input_event(KEY_PRESS, "9", 0.0),
        input_event(KEY_RELEASE, "LEFTSHIFT", 0.0),
        input_event(KEY_RELEASE, "9", 0.1),
    };

    log.debug("key remap with modifier: {any}", .{keyboard.event_provider.outputs.items});
    try testing.expectEqualSlices(InputEvent, &expected, keyboard.event_provider.outputs.items);
}

test "Modifiers don't leak to next key" {
    var layer: Layer = PASSTHROUGH;
    // Map "Q" to "(" (shift+9)
    map(&layer, "Q", s("9"));

    const inputs = [_]InputEvent{
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_PRESS, "W", 0.1),
        input_event(KEY_RELEASE, "W", 0.2),
        input_event(KEY_RELEASE, "Q", 0.3),
    };
    var keyboard = testKeyboardAlloc(&.{layer}, &inputs);
    defer keyboard.deinit();
    keyboard.loop();

    const expected = [_]InputEvent{
        input_event(KEY_PRESS, "LEFTSHIFT", 0.0),
        input_event(KEY_PRESS, "9", 0.0),
        input_event(KEY_RELEASE, "LEFTSHIFT", 0.0),
        input_event(KEY_PRESS, "W", 0.1),
        input_event(KEY_RELEASE, "W", 0.2),
        input_event(KEY_RELEASE, "9", 0.3),
    };
    try testing.expectEqualSlices(InputEvent, &expected, keyboard.event_provider.outputs.items);
}

test "Layer toggle" {
    var layer0 = PASSTHROUGH;
    var layer1 = PASSTHROUGH;
    // On both layers: map tab to toggle(layer1)
    map(&layer0, "TAB", lt(1));
    map(&layer1, "TAB", lt(1));
    // On second layer: map key "Q" to "A"
    map(&layer1, "Q", k("A"));

    const inputs = [_]InputEvent{
        // layer 0
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_RELEASE, "Q", 0.1),
        input_event(KEY_PRESS, "TAB", 0.2),
        input_event(KEY_RELEASE, "TAB", 0.3),
        // layer 1
        input_event(KEY_PRESS, "Q", 0.4),
        input_event(KEY_RELEASE, "Q", 0.5),
        input_event(KEY_PRESS, "TAB", 0.6),
        input_event(KEY_RELEASE, "TAB", 0.7),
        // back to layer 0
        input_event(KEY_PRESS, "Q", 0.8),
        input_event(KEY_RELEASE, "Q", 0.9),
        // quick switch to layer 1
        input_event(KEY_PRESS, "TAB", 1.0),
        input_event(KEY_PRESS, "Q", 1.1),
        input_event(KEY_RELEASE, "TAB", 1.2),
        input_event(KEY_RELEASE, "Q", 1.3),
    };
    var keyboard = testKeyboardAlloc(&.{ layer0, layer1 }, &inputs);
    defer keyboard.deinit();
    keyboard.loop();

    const expected = [_]InputEvent{
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_RELEASE, "Q", 0.1),
        input_event(KEY_PRESS, "A", 0.4),
        input_event(KEY_RELEASE, "A", 0.5),
        input_event(KEY_PRESS, "Q", 0.8),
        input_event(KEY_RELEASE, "Q", 0.9),
        input_event(KEY_PRESS, "A", 1.1),
        input_event(KEY_RELEASE, "A", 1.3),
    };
    try testing.expectEqualSlices(InputEvent, &expected, keyboard.event_provider.outputs.items);
}

test "Handle unexpected events" {
    const layout = [_]Layer{PASSTHROUGH};

    const inputs = [_]InputEvent{
        input_event(KEY_RELEASE, "Q", 0.1),
    };
    var keyboard = testKeyboardAlloc(&layout, &inputs);
    defer keyboard.deinit();
    keyboard.loop();

    try testing.expectEqualSlices(InputEvent, &inputs, keyboard.event_provider.outputs.items);
}

test "PASSTHROUGH layout passes all keyboard events through" {
    const layout = [_]Layer{PASSTHROUGH};

    const inputs = [_]InputEvent{
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_RELEASE, "Q", 0.1),
    };
    var keyboard = testKeyboardAlloc(&layout, &inputs);
    defer keyboard.deinit();
    keyboard.loop();

    try testing.expectEqualSlices(InputEvent, &inputs, keyboard.event_provider.outputs.items);
}

test "Transparent pass to layer below" {
    var layer0 = PASSTHROUGH;
    var layer1 = PASSTHROUGH;
    // Base layer is Azerty
    map(&layer0, "Q", k("A"));
    map(&layer0, "W", k("Z"));
    map(&layer0, "TAB", lt(1));
    // On second layer: "Q" is transparent, "W" is "W"
    map(&layer1, "Q", __);
    map(&layer1, "W", k("W"));

    const inputs = [_]InputEvent{
        // layer 0
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_PRESS, "W", 0.1),
        input_event(KEY_PRESS, "TAB", 0.2),
        // layer 1
        input_event(KEY_PRESS, "Q", 0.3),
        input_event(KEY_PRESS, "W", 0.4),
        input_event(KEY_PRESS, "TAB", 0.5),
        // back to layer 0
        input_event(KEY_PRESS, "Q", 0.6),
        input_event(KEY_PRESS, "W", 0.7),
    };
    var keyboard = testKeyboardAlloc(&.{ layer0, layer1 }, &inputs);
    defer keyboard.deinit();
    keyboard.loop();

    const expected = [_]InputEvent{
        input_event(KEY_PRESS, "A", 0.0),
        input_event(KEY_PRESS, "Z", 0.1),
        input_event(KEY_PRESS, "A", 0.3),
        input_event(KEY_PRESS, "W", 0.4),
        input_event(KEY_PRESS, "A", 0.6),
        input_event(KEY_PRESS, "Z", 0.7),
    };
    try testing.expectEqualSlices(InputEvent, &expected, keyboard.event_provider.outputs.items);
}

test "Layer Hold" {
    var layer0 = PASSTHROUGH;
    var layer1 = PASSTHROUGH;
    // On both layers: map tab to toggle(layer1)
    map(&layer0, "TAB", lh("TAB", 1));
    // On second layer: map key "Q" to "A"
    map(&layer1, "Q", k("A"));

    const inputs = [_]InputEvent{
        // layer 0
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_RELEASE, "Q", 0.1),
        // Quick tap on "TAB"
        input_event(KEY_PRESS, "TAB", 0.2),
        input_event(KEY_RELEASE, "TAB", 0.3),
        // Type "Q" while pressing "TAB", switch to layer 1
        input_event(KEY_PRESS, "TAB", 0.4),
        input_event(KEY_PRESS, "Q", 0.5),
        input_event(KEY_RELEASE, "Q", 0.6),
        input_event(KEY_RELEASE, "TAB", 0.7),
        // back to layer 0
        input_event(KEY_PRESS, "Q", 0.8),
        input_event(KEY_RELEASE, "Q", 0.9),

        // Press layer 1 while there is an ongoing keypress
        input_event(KEY_PRESS, "Q", 1.0),
        input_event(KEY_PRESS, "TAB", 1.1),
        input_event(KEY_RELEASE, "Q", 1.2),
        input_event(KEY_RELEASE, "TAB", 1.6),

        // Release layer 1 while there is an ongoing keypress
        input_event(KEY_PRESS, "TAB", 2.0),
        input_event(KEY_PRESS, "Q", 2.5),
        input_event(KEY_RELEASE, "TAB", 2.6),
        input_event(KEY_RELEASE, "Q", 2.7),
    };
    var keyboard = testKeyboardAlloc(&.{ layer0, layer1 }, &inputs);
    defer keyboard.deinit();
    keyboard.loop();

    const expected = [_]InputEvent{
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_RELEASE, "Q", 0.1),
        input_event(KEY_PRESS, "TAB", 0.2),
        input_event(KEY_RELEASE, "TAB", 0.3),
        input_event(KEY_PRESS, "A", 0.5),
        input_event(KEY_RELEASE, "A", 0.6),
        input_event(KEY_PRESS, "Q", 0.8),
        input_event(KEY_RELEASE, "Q", 0.9),

        // Press layer 1 while there is an ongoing keypress
        input_event(KEY_PRESS, "Q", 1.0),
        input_event(KEY_RELEASE, "Q", 1.2),

        // Release the original key
        input_event(KEY_PRESS, "A", 2.5),
        input_event(KEY_RELEASE, "A", 2.7),
    };
    try testing.expectEqualSlices(InputEvent, &expected, keyboard.event_provider.outputs.items);
}

test "Layer Hold With Modifiers From Layer Below" {
    var layer0 = PASSTHROUGH;
    var layer1 = PASSTHROUGH;
    map(&layer0, "TAB", lh("TAB", 1));
    map(&layer0, "CAPSLOCK", k("LEFTSHIFT"));
    map(&layer1, "F", k("RIGHTBRACE"));

    const inputs = [_]InputEvent{
        // Hold "Layer1"+"CAPSLOCK"+"F"
        // This should yield a shifted ]
        input_event(KEY_PRESS, "TAB", 0.0),
        input_event(KEY_PRESS, "CAPSLOCK", 0.1),
        input_event(KEY_PRESS, "F", 0.2),
        input_event(KEY_RELEASE, "F", 0.3),
        input_event(KEY_REPEAT, "CAPSLOCK", 0.35),
        input_event(KEY_RELEASE, "TAB", 0.4),
        input_event(KEY_REPEAT, "CAPSLOCK", 0.45),
        input_event(KEY_RELEASE, "CAPSLOCK", 0.5),
    };
    var keyboard = testKeyboardAlloc(&.{ layer0, layer1 }, &inputs);
    defer keyboard.deinit();
    keyboard.loop();

    const expected = [_]InputEvent{
        input_event(KEY_PRESS, "LEFTSHIFT", 0.1),
        input_event(KEY_PRESS, "RIGHTBRACE", 0.2),
        input_event(KEY_RELEASE, "RIGHTBRACE", 0.3),
        input_event(KEY_RELEASE, "LEFTSHIFT", 0.5),
    };
    try testing.expectEqualSlices(InputEvent, &expected, keyboard.event_provider.outputs.items);
}

test "Mouse Move" {
    const m_up = Action{ .mouse_move = .{ .stepX = 10 } };
    const m_down_right = Action{ .mouse_move = .{ .stepX = -10, .stepY = 10 } };

    var layer0 = PASSTHROUGH;
    map(&layer0, "W", m_up);
    map(&layer0, "D", m_down_right);

    const inputs = [_]InputEvent{
        input_event(KEY_PRESS, "W", 0.0),
        input_event(KEY_RELEASE, "W", 0.1),
        input_event(KEY_PRESS, "D", 0.2),
        input_event(KEY_RELEASE, "D", 0.3),
    };
    var keyboard = testKeyboardAlloc(&.{layer0}, &inputs);
    defer keyboard.deinit();
    keyboard.loop();

    const expected = [_]InputEvent{
        _event(linux.EV_REL, linux.REL_X, 10, 0.0),
        _event(linux.EV_REL, linux.REL_X, -10, 0.2),
        _event(linux.EV_REL, linux.REL_Y, 10, 0.2),
    };
    try testing.expectEqualSlices(InputEvent, &expected, keyboard.event_provider.outputs.items);
}

/// Shortcut to create an InputEvent, using float for timestamp.
pub fn input_event(event: u8, comptime keyname: []const u8, time: f64) InputEvent {
    return .{
        .type = linux.EV_KEY,
        .value = event,
        .code = resolve(keyname),
        // The way time is stored actually depends of the compile target...
        // TODO: handle the case where sec and usec are part of the InputEvent struct.
        .time = linux_time(time),
    };
}

test "input event" {
    try testing.expectEqual(@as(u32, 24), @sizeOf(InputEvent));
}

fn _event(_type: u16, code: u16, value: i32, time: f64) InputEvent {
    return .{ .type = _type, .code = code, .value = value, .time = linux_time(time) };
}

fn linux_time(time: f64) linux.timeval {
    const time_modf = math.modf(time);
    const seconds = math.lossyCast(u32, time_modf.ipart);
    const micro_seconds = math.lossyCast(u32, time_modf.fpart * 1e6);
    return linux.timeval{ .tv_sec = seconds, .tv_usec = micro_seconds };
}

test "input_event helper correctly converts micro seconds" {
    try testing.expectEqual(
        InputEvent{
            .type = linux.EV_KEY,
            .value = 1,
            .code = linux.KEY_Q,
            .time = .{ .tv_sec = 123, .tv_usec = 456000 },
        },
        input_event(KEY_PRESS, "Q", 123.456),
    );
    try testing.expectEqual(
        InputEvent{
            .type = linux.EV_KEY,
            .value = 1,
            .code = linux.KEY_Q,
            .time = .{ .tv_sec = 123, .tv_usec = 456999 },
        },
        input_event(KEY_PRESS, "Q", 123.457),
    );
}

fn _input_delta_ms(t1: f64, t2: f64) i32 {
    return delta_ms(
        input_event(KEY_PRESS, "Q", t1),
        input_event(KEY_PRESS, "Q", t2),
    );
}

test "delta_ms" {
    try testing.expectEqual(@as(i32, 1), _input_delta_ms(123.456, 123.45701));
    try testing.expectEqual(@as(i32, 0), _input_delta_ms(123.456, 123.45650));
    try testing.expectEqual(@as(i32, -1), _input_delta_ms(123.45701, 123.456));
    try testing.expectEqual(@as(i32, 1000), _input_delta_ms(123, 124));
}

// Layout DSL: create a layer using the ANSI layout
pub fn ansi(
    number_row: [13]Action,
    top_row: [14]Action,
    middle_row: [13]Action,
    bottom_row: [12]Action,
) Layer {
    var layer = PASSTHROUGH;
    map(&layer, "GRAVE", number_row[0]);
    map(&layer, "1", number_row[1]);
    map(&layer, "2", number_row[2]);
    map(&layer, "3", number_row[3]);
    map(&layer, "4", number_row[4]);
    map(&layer, "5", number_row[5]);
    map(&layer, "6", number_row[6]);
    map(&layer, "7", number_row[7]);
    map(&layer, "8", number_row[8]);
    map(&layer, "9", number_row[9]);
    map(&layer, "0", number_row[10]);
    map(&layer, "MINUS", number_row[11]);
    map(&layer, "EQUAL", number_row[12]);

    map(&layer, "TAB", top_row[0]);
    map(&layer, "Q", top_row[1]);
    map(&layer, "W", top_row[2]);
    map(&layer, "E", top_row[3]);
    map(&layer, "R", top_row[4]);
    map(&layer, "T", top_row[5]);
    map(&layer, "Y", top_row[6]);
    map(&layer, "U", top_row[7]);
    map(&layer, "I", top_row[8]);
    map(&layer, "O", top_row[9]);
    map(&layer, "P", top_row[10]);
    map(&layer, "LEFTBRACE", top_row[11]);
    map(&layer, "RIGHTBRACE", top_row[12]);
    map(&layer, "BACKSLASH", top_row[13]);

    map(&layer, "CAPSLOCK", middle_row[0]);
    map(&layer, "A", middle_row[1]);
    map(&layer, "S", middle_row[2]);
    map(&layer, "D", middle_row[3]);
    map(&layer, "F", middle_row[4]);
    map(&layer, "G", middle_row[5]);
    map(&layer, "H", middle_row[6]);
    map(&layer, "J", middle_row[7]);
    map(&layer, "K", middle_row[8]);
    map(&layer, "L", middle_row[9]);
    map(&layer, "SEMICOLON", middle_row[10]);
    map(&layer, "APOSTROPHE", middle_row[11]);
    map(&layer, "ENTER", middle_row[12]);

    map(&layer, "LEFTSHIFT", bottom_row[0]);
    map(&layer, "Z", bottom_row[1]);
    map(&layer, "X", bottom_row[2]);
    map(&layer, "C", bottom_row[3]);
    map(&layer, "V", bottom_row[4]);
    map(&layer, "B", bottom_row[5]);
    map(&layer, "N", bottom_row[6]);
    map(&layer, "M", bottom_row[7]);
    map(&layer, "COMMA", bottom_row[8]);
    map(&layer, "DOT", bottom_row[9]);
    map(&layer, "SLASH", bottom_row[10]);
    map(&layer, "RIGHTSHIFT", bottom_row[11]);

    return layer;
}
