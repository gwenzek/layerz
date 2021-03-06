/// Reference https://www.kernel.org/doc/html/v4.15/input/event-codes.html
const std = @import("std");
const io = std.io;
const math = std.math;
const log = std.log;
pub const linux = @cImport(@cInclude("linux/input.h"));

var _start_time: i64 = -1;
var _start_time_ns: i64 = 0;
/// This is a port of linux input_event struct.
/// The C code has different way of storing the time depending on the machine
/// this isn't currently supported in the Zig.
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
                    try std.fmt.format(writer, "{{ EV_KEY({d}, {d}) ({d:.3}) }}", .{ input.code, input.value, time });
                    return;
                },
            };
            try std.fmt.format(writer, "{{{s}({d}) ({d:.3})}}", .{ value, input.code, time });
        } else {
            const ev_type = switch (input.value) {
                linux.EV_REL => "EV_REL",
                linux.EV_SYN => "EV_SYN",
                linux.EV_MSC => "EV_MSC",
                else => {
                    try std.fmt.format(writer, "{{EV({d})({d}, {d}) ({d:.3})}}", .{ input.type, input.code, input.value, time });
                    return;
                },
            };
            try std.fmt.format(writer, "{{{s}({d}, {d}) ({d:.3})}}", .{ ev_type, input.code, input.value, time });
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

    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&c_struct),
        std.mem.asBytes(&zig_struct),
    );
}

// Those values are documented in linux doc:
// https://www.kernel.org/doc/html/v4.15/input/event-codes.html#ev-key
const KEY_PRESS = 1;
const KEY_RELEASE = 0;
const KEY_REPEAT = 2;

const LayerzActionKind = enum {
    tap,
    mod_tap,
    layer_hold,
    layer_toggle,
    disabled,
    transparent,
    mouse_move,
};

pub const LayerzActionTap = struct { key: u8 };
pub const LayerzActionModTap = struct { key: u8, mod: u8 };
pub const LayerzActionLayerHold = struct { key: u8, layer: u8, delay_ms: u16 = 200 };
pub const LayerzActionLayerToggle = struct { layer: u8 };
pub const LayerzActionDisabled = struct {};
pub const LayerzActionTransparent = struct {};
pub const LayerzActionMouseMove = struct { key: u8 = linux.REL_X, stepX: i16 = 0, stepY: i16 = 0 };

pub const LayerzAction = union(LayerzActionKind) {
    tap: LayerzActionTap,
    mod_tap: LayerzActionModTap,
    layer_hold: LayerzActionLayerHold,
    layer_toggle: LayerzActionLayerToggle,
    disabled: LayerzActionDisabled,
    transparent: LayerzActionTransparent,
    /// Move the mouse or wheel. This doesn't seem to work on my keyboard.
    /// Maybe the device need to be registered with mouse capabilities ?
    mouse_move: LayerzActionMouseMove,
};

const NUM_KEYS = 256;
pub const Layer = [NUM_KEYS]LayerzAction;

pub fn resolve(comptime keyname: []const u8) u8 {
    const fullname = "KEY_" ++ keyname;
    if (!@hasDecl(linux, fullname)) {
        @compileError("input-event-codes.h doesn't declare: " ++ fullname);
    }
    return @field(linux, fullname);
}

test "Resolve keyname" {
    try std.testing.expectEqual(linux.KEY_Q, resolve("Q"));
    try std.testing.expectEqual(linux.KEY_TAB, resolve("TAB"));
    try std.testing.expectEqual(linux.KEY_LEFTSHIFT, resolve("LEFTSHIFT"));
}

/// Layout DSL: tap the given key
pub fn k(comptime keyname: []const u8) LayerzAction {
    return .{ .tap = .{ .key = resolve(keyname) } };
}

/// Layout DSL: tap shift and the given key
pub fn s(comptime keyname: []const u8) LayerzAction {
    return .{
        .mod_tap = .{ .key = resolve(keyname), .mod = linux.KEY_LEFTSHIFT },
    };
}

/// Layout DSL: tap ctrl and the given key
pub fn ctrl(comptime keyname: []const u8) LayerzAction {
    return .{
        .mod_tap = .{ .key = resolve(keyname), .mod = linux.KEY_LEFTCTRL },
    };
}

/// Layout DSL: tap altgr (right alt) and the given key. Useful for inputing localized chars.
pub fn altgr(comptime keyname: []const u8) LayerzAction {
    return .{
        .mod_tap = .{ .key = resolve(keyname), .mod = linux.KEY_RIGHTALT },
    };
}

/// Layout DSL: toggle a layer
pub fn lt(layer: u8) LayerzAction {
    return .{
        .layer_toggle = .{ .layer = layer },
    };
}

/// Layout DSL: toggle a layer when hold, tap a key when tapped
pub fn lh(comptime keyname: []const u8, layer: u8) LayerzAction {
    return .{
        .layer_hold = .{ .layer = layer, .key = resolve(keyname) },
    };
}

/// Layout DSL: disable a key
pub const xx: LayerzAction = .{ .disabled = .{} };

/// Layout DSL: pass the key to the layer below
pub const __: LayerzAction = .{ .transparent = .{} };

pub const PASSTHROUGH: Layer = [_]LayerzAction{__} ** NUM_KEYS;

pub fn map(layer: *Layer, comptime src_key: []const u8, action: LayerzAction) void {
    layer[resolve(src_key)] = action;
}

/// From kernel docs:
/// Used to synchronize and separate events into packets of input data changes
/// occurring at the same moment in time.
/// For example, motion of a mouse may set the REL_X and REL_Y values for one motion,
/// then emit a SYN_REPORT.
/// The next motion will emit more REL_X and REL_Y values and send another SYN_REPORT.
const sync_report = InputEvent{
    .type = linux.EV_SYN,
    .code = linux.SYN_REPORT,
    .value = 0,
    .time = undefined,
};

/// From kernel docs:
/// Used to indicate buffer overrun in the evdev client???s event queue.
/// Client should ignore all events up to and including next SYN_REPORT event
/// and query the device (using EVIOCG* ioctls) to obtain its current state.
const sync_dropped = InputEvent{
    .type = linux.EV_SYN,
    .code = linux.SYN_DROPPED,
    .value = 0,
    .time = undefined,
};

pub const EventWriter = fn (event: InputEvent) void;
pub const DelayedHandler = fn (
    keyboard: *KeyboardState,
    event: InputEvent,
    next_event: InputEvent,
) void;

var _special_release_enter: InputEvent = undefined;

pub const KeyboardState = struct {
    layout: []const [NUM_KEYS]LayerzAction,
    writer: EventWriter = write_event_to_stdout,

    base_layer: u8 = 0,
    layer: u8 = 0,
    maybe_layer: LayerzActionLayerHold = undefined,
    delayed_handler: ?*const DelayedHandler = null,
    // we should have an allocator, there are more thing to store
    _stack_buffer: [32 * @sizeOf(InputEvent)]u8 = undefined,
    stack: std.ArrayListUnmanaged(InputEvent) = undefined,
    key_state: [NUM_KEYS]u8 = [_]u8{0} ** NUM_KEYS,

    const Self = @This();

    pub fn init(self: *Self) void {
        // Release enter key. This is needed when you're typing f
        // TODO: this doesn't work
        _start_time = std.time.timestamp();
        _special_release_enter = input_event(KEY_RELEASE, "ENTER", std.math.lossyCast(f64, _start_time));
        self.writer(_special_release_enter);
        self.writer(sync_report);

        var alloc = std.heap.FixedBufferAllocator.init(&self._stack_buffer);
        self.stack = std.ArrayListUnmanaged(InputEvent){};
        self.stack.ensureTotalCapacity(alloc.allocator(), 16) catch unreachable;
        // TODO: should we resolve the transparent actions now ?
    }

    pub fn handle(keyboard: *Self, input: InputEvent) void {
        if (input.type == linux.EV_MSC and input.code == linux.MSC_SCAN) {
            keyboard.writer(input);
            return;
        }

        // make mouse and touchpad events consume pressed taps
        // if (input.type == linux.EV_REL or input.type == linux.EV_ABS)
        //     keyboard.consume_pressed();

        // forward anything that is not a key event, including sync events
        if (input.type != linux.EV_KEY or input.code >= NUM_KEYS) {
            keyboard.writer(input);
            return;
        }
        std.log.debug("read {}", .{input});

        const stack_len = keyboard.stack.items.len;
        if (stack_len > 0) {
            if (keyboard.delayed_handler) |handler| {
                const last_input = keyboard.stack.items[stack_len - 1];
                handler.*(keyboard, last_input, input);
                return;
            }
        }

        const action = keyboard.resolve_action(input);
        keyboard.handle_action(action, input);
    }

    fn resolve_action(keyboard: *Self, input: InputEvent) LayerzAction {
        // get the layer on which this event happen
        const key_layer = switch (input.value) {
            KEY_REPEAT => {
                // TODO: check if it's right to swallow repeats event
                // linux console, X, wayland handles repeat
                return xx;
            },
            KEY_PRESS => keyboard.layer,
            KEY_RELEASE => keyboard.key_state[input.code],
            else => {
                std.log.warn("ignoring unkown event {}", .{input});
                return xx;
            },
        };
        if (input.value == KEY_PRESS) {
            // release delayed events
            keyboard.consume_pressed();
        }
        keyboard.key_state[input.code] = key_layer;
        if (input.code == resolve("CAPSLOCK")) {
            std.log.debug("CAPSLOCK is on layer {}", .{key_layer});
        }
        return keyboard.layout[key_layer][input.code];
    }

    fn handle_action(keyboard: *Self, action: LayerzAction, input: InputEvent) void {
        // TODO: generate this switch ?
        switch (action) {
            .tap => |val| keyboard.handle_tap(val, input),
            .mod_tap => |val| keyboard.handle_mod_tap(val, input),
            .layer_toggle => |val| keyboard.handle_layer_toggle(val, input),
            .layer_hold => |val| keyboard.handle_layer_hold(val, input),
            .disabled => |val| keyboard.handle_disabled(val, input),
            .transparent => |val| keyboard.handle_transparent(val, input),
            .mouse_move => |val| keyboard.handle_mouse_move(val, input),
        }
    }

    fn handle_tap(keyboard: *Self, tap: LayerzActionTap, input: InputEvent) void {
        var output = input;
        output.code = tap.key;
        keyboard.writer(output);
    }

    /// Output two keys. This is useful for modifiers.
    // TODO: support more than one mod
    fn handle_mod_tap(keyboard: *Self, tap: LayerzActionModTap, input: InputEvent) void {
        var output = input;
        output.code = tap.key;
        var mod_press: InputEvent = output;
        mod_press.code = tap.mod;
        if (input.value == KEY_PRESS) {
            // First press the modifier then the key.
            keyboard.writer(mod_press);
            keyboard.writer(output);

            // Delay the modifier release to the next key press.
            var mod_release = keyboard.stack.addOneAssumeCapacity();
            mod_release.* = mod_press;
            mod_release.value = KEY_RELEASE;
        } else if (input.value == KEY_RELEASE) {
            keyboard.writer(output);
            var i = @intCast(u8, keyboard.stack.items.len);
            // Release the mod if it hasn't been done before.
            while (i > 0) : (i -= 1) {
                var mod_release = keyboard.stack.items[i - 1];
                if (mod_release.code == tap.mod) {
                    keyboard.writer(mod_release);
                    _ = keyboard.stack.orderedRemove(i - 1);
                }
            }
        } else {
            keyboard.writer(output);
        }
    }

    /// Switch between layers
    // TODO: could we have a startup check to see if we can get stuck on a layer ?
    fn handle_layer_toggle(keyboard: *Self, layer_toggle: LayerzActionLayerToggle, event: InputEvent) void {
        switch (event.value) {
            KEY_PRESS => {
                if (keyboard.layer != layer_toggle.layer) {
                    keyboard.layer = layer_toggle.layer;
                } else {
                    keyboard.layer = keyboard.base_layer;
                }
            },
            else => {},
        }
    }

    fn handle_layer_hold(keyboard: *Self, layer_hold: LayerzActionLayerHold, event: InputEvent) void {
        switch (event.value) {
            KEY_PRESS => {
                keyboard.maybe_layer = layer_hold;
                keyboard.delayed_handler = &handle_layer_hold_second;
                var delayed = keyboard.stack.addOneAssumeCapacity();
                delayed.* = event;
                delayed.code = layer_hold.key;
                std.log.debug("Maybe we are holding a layer: {}. Delay event: {}", .{ layer_hold.layer, event });
            },
            KEY_RELEASE => {
                keyboard.delayed_handler = null;
                if (keyboard.layer == layer_hold.layer) {
                    std.log.debug("Disabling layer: {} on {}", .{ layer_hold.layer, event });
                    keyboard.layer = keyboard.base_layer;
                } else {
                    keyboard.handle_tap(.{ .key = layer_hold.key }, event);
                }
            },
            else => {},
        }
    }

    fn handle_layer_hold_second(
        keyboard: *Self,
        event: InputEvent,
        next_event: InputEvent,
    ) void {
        const action = keyboard.layout[keyboard.base_layer][event.code];
        const layer_hold = switch (action) {
            .layer_hold => |val| val,
            else => {
                std.log.warn("Inconsistent internal state, expected a LayerHold action on top of the stack, but found: {}", .{action});
                keyboard.delayed_handler = null;
                keyboard.consume_pressed();
                return;
            },
        };
        if (event.code == next_event.code) {
            // Another event on the layer key
            if (next_event.value == KEY_RELEASE) {
                if (delta_ms(event, next_event) < layer_hold.delay_ms) {
                    // We have just tapped on the layer button, emit the key
                    std.log.debug("Quick tap on layer {})", .{layer_hold});
                    keyboard.writer(event);
                    keyboard.handle_tap(.{ .key = layer_hold.key }, next_event);
                } else {
                    // We have been holding for a long time, do nothing
                }
                keyboard.delayed_handler = null;
                _ = keyboard.stack.pop();
            }
        } else {
            if (next_event.value == KEY_PRESS) {
                // TODO: handle quick typing ?
                // if (delta_ms(event, next_event) > layer_hold.delay_ms) ...

                std.log.debug("Holding layer {}", .{layer_hold});
                // We are holding the layer !
                keyboard.layer = layer_hold.layer;
                // Disable handle_layer_hold_second, resume normal key handling
                keyboard.delayed_handler = null;
                _ = keyboard.stack.pop();
            }
            // Call regular key handling code with the new layer
            const next_action = keyboard.resolve_action(next_event);
            keyboard.handle_action(next_action, next_event);
        }
    }

    /// Do nothing.
    fn handle_disabled(keyboard: *const Self, layer_hold: LayerzActionDisabled, event: InputEvent) void {
        _ = keyboard;
        _ = layer_hold;
        _ = event;
    }

    /// Do the action from the base layer instead.
    /// If we are already on the base layer, just forward the input event.
    fn handle_transparent(keyboard: *Self, transparent: LayerzActionTransparent, event: InputEvent) void {
        _ = transparent;
        const key_layer = keyboard.key_state[event.code];
        if (key_layer == keyboard.base_layer) {
            keyboard.writer(event);
        } else {
            const base_action = keyboard.layout[keyboard.base_layer][event.code];
            switch (base_action) {
                // We need to handle transparent explicitly otherwise we create an infinite loop.
                .transparent => keyboard.writer(event),
                else => keyboard.handle_action(base_action, event),
            }
        }
    }

    fn handle_mouse_move(keyboard: *Self, mouse_move: LayerzActionMouseMove, input: InputEvent) void {
        if (input.value == KEY_RELEASE) return;
        var output = input;
        output.type = linux.EV_REL;
        output.code = mouse_move.key;
        switch (mouse_move.key) {
            linux.REL_X => {
                output.code = linux.REL_X;
                output.value = mouse_move.stepX;
                keyboard.writer(output);
                output.code = linux.REL_Y;
                output.value = mouse_move.stepY;
                keyboard.writer(output);
            },
            linux.REL_WHEEL, linux.REL_DIAL => {
                output.value = mouse_move.stepX;
                keyboard.writer(output);
            },
            linux.REL_HWHEEL => {
                output.value = mouse_move.stepY;
                keyboard.writer(output);
            },
            // Ideally this should be detected at compile time
            else => {},
        }
    }

    /// Read events from stdinput and handle them.
    pub fn loop(keyboard: *Self) void {
        var input: InputEvent = undefined;
        const buffer = std.mem.asBytes(&input);
        while (io.getStdIn().read(buffer)) {
            keyboard.handle(input);
        } else |err| {
            std.debug.panic("Couldn't read event from stdin: {}", .{err});
        }
    }

    pub fn consume_pressed(keyboard: *KeyboardState) void {
        while (keyboard.stack.items.len > 0) {
            var delayed_event = keyboard.stack.pop();
            keyboard.writer(delayed_event);
        }
    }
};

pub fn write_event_to_stdout(event: InputEvent) void {
    const buffer = std.mem.asBytes(&event);
    std.log.debug("wrote {}", .{event});
    if (event.code == resolve("CAPSLOCK")) {
        std.log.warn("!!! writing CAPSLOCK !!!", .{});
        std.debug.panic("CAPSLOCK shouldn't be emitted", .{});
    }

    _ = io.getStdOut().write(buffer) catch std.debug.panic("Couldn't write event {s} to stdout", .{event});
}

fn delta_ms(event1: InputEvent, event2: InputEvent) i32 {
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

test "Key remap with modifier" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();

    var layer: [NUM_KEYS]LayerzAction = PASSTHROUGH;
    // Map "Q" to "(" (shift+9)
    map(&layer, "Q", s("9"));

    var keyboard = KeyboardState{ .layout = &.{layer}, .writer = testing_write_event };
    keyboard.init();

    const inputs = [_]InputEvent{
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_RELEASE, "Q", 0.1),
    };
    for (inputs) |input| keyboard.handle(input);

    const expected = [_]InputEvent{
        input_event(KEY_PRESS, "LEFTSHIFT", 0.0),
        input_event(KEY_PRESS, "9", 0.0),
        input_event(KEY_RELEASE, "9", 0.1),
        input_event(KEY_RELEASE, "LEFTSHIFT", 0.0),
    };
    try std.testing.expectEqualSlices(InputEvent, &expected, test_outputs.items);
}

test "Modifiers don't leak to next key" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();

    var layer: [NUM_KEYS]LayerzAction = PASSTHROUGH;
    // Map "Q" to "(" (shift+9)
    map(&layer, "Q", s("9"));

    var keyboard = KeyboardState{ .layout = &.{layer}, .writer = testing_write_event };
    keyboard.init();

    const inputs = [_]InputEvent{
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_PRESS, "W", 0.1),
        input_event(KEY_RELEASE, "W", 0.2),
        input_event(KEY_RELEASE, "Q", 0.3),
    };
    for (inputs) |input| keyboard.handle(input);

    const expected = [_]InputEvent{
        input_event(KEY_PRESS, "LEFTSHIFT", 0.0),
        input_event(KEY_PRESS, "9", 0.0),
        input_event(KEY_RELEASE, "LEFTSHIFT", 0.0),
        input_event(KEY_PRESS, "W", 0.1),
        input_event(KEY_RELEASE, "W", 0.2),
        input_event(KEY_RELEASE, "9", 0.3),
    };
    try std.testing.expectEqualSlices(InputEvent, &expected, test_outputs.items);
}

test "Layer toggle" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();

    var layer0 = PASSTHROUGH;
    var layer1 = PASSTHROUGH;
    // On both layers: map tab to toggle(layer1)
    map(&layer0, "TAB", lt(1));
    map(&layer1, "TAB", lt(1));
    // On second layer: map key "Q" to "A"
    map(&layer1, "Q", k("A"));

    var layout = [_]Layer{ layer0, layer1 };
    var keyboard = KeyboardState{ .layout = &layout, .writer = testing_write_event };
    keyboard.init();

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
    for (inputs) |input| keyboard.handle(input);

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
    try std.testing.expectEqualSlices(InputEvent, &expected, test_outputs.items);
}

test "Handle unexpected events" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();
    const layout = [_]Layer{PASSTHROUGH};
    var keyboard = KeyboardState{ .layout = &layout, .writer = testing_write_event };
    keyboard.init();

    const inputs = [_]InputEvent{
        input_event(KEY_RELEASE, "Q", 0.1),
    };
    for (inputs) |input| keyboard.handle(input);

    try std.testing.expectEqualSlices(InputEvent, &inputs, test_outputs.items);
}

test "PASSTHROUGH layout passes all keyboard events through" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();
    const layout = [_]Layer{PASSTHROUGH};
    var keyboard = KeyboardState{ .layout = &layout, .writer = testing_write_event };
    keyboard.init();

    const inputs = [_]InputEvent{
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_RELEASE, "Q", 0.1),
    };
    for (inputs) |input| keyboard.handle(input);

    try std.testing.expectEqualSlices(InputEvent, &inputs, test_outputs.items);
}

test "Transparent pass to layer below" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();

    var layer0 = PASSTHROUGH;
    var layer1 = PASSTHROUGH;
    // Base layer is Azerty
    map(&layer0, "Q", k("A"));
    map(&layer0, "W", k("Z"));
    map(&layer0, "TAB", lt(1));
    // On second layer: "Q" is transparent, "W" is "W"
    map(&layer1, "Q", __);
    map(&layer1, "W", k("W"));

    var layout = [_]Layer{ layer0, layer1 };
    var keyboard = KeyboardState{ .layout = &layout, .writer = testing_write_event };
    keyboard.init();

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
    for (inputs) |input| keyboard.handle(input);

    const expected = [_]InputEvent{
        input_event(KEY_PRESS, "A", 0.0),
        input_event(KEY_PRESS, "Z", 0.1),
        input_event(KEY_PRESS, "A", 0.3),
        input_event(KEY_PRESS, "W", 0.4),
        input_event(KEY_PRESS, "A", 0.6),
        input_event(KEY_PRESS, "Z", 0.7),
    };
    try std.testing.expectEqualSlices(InputEvent, &expected, test_outputs.items);
}

test "Layer Hold" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();

    var layer0 = PASSTHROUGH;
    var layer1 = PASSTHROUGH;
    // On both layers: map tab to toggle(layer1)
    map(&layer0, "TAB", lh("TAB", 1));
    // On second layer: map key "Q" to "A"
    map(&layer1, "Q", k("A"));

    var layout = [_]Layer{ layer0, layer1 };
    var keyboard = KeyboardState{ .layout = &layout, .writer = testing_write_event };
    keyboard.init();

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
    for (inputs) |input| keyboard.handle(input);

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
    try std.testing.expectEqualSlices(InputEvent, &expected, test_outputs.items);
}

test "Layer Hold With Modifiers From Layer Below" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();

    var layer0 = PASSTHROUGH;
    var layer1 = PASSTHROUGH;
    map(&layer0, "TAB", lh("TAB", 1));
    map(&layer0, "CAPSLOCK", k("LEFTSHIFT"));
    map(&layer1, "F", k("RIGHTBRACE"));

    var layout = [_]Layer{ layer0, layer1 };
    var keyboard = KeyboardState{ .layout = &layout, .writer = testing_write_event };
    keyboard.init();

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
    for (inputs) |input| keyboard.handle(input);

    const expected = [_]InputEvent{
        input_event(KEY_PRESS, "LEFTSHIFT", 0.1),
        input_event(KEY_PRESS, "RIGHTBRACE", 0.2),
        input_event(KEY_RELEASE, "RIGHTBRACE", 0.3),
        input_event(KEY_RELEASE, "LEFTSHIFT", 0.5),
    };
    try std.testing.expectEqualSlices(InputEvent, &expected, test_outputs.items);
}

test "Mouse Move" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();

    const m_up = LayerzAction{ .mouse_move = .{ .stepX = 10 } };
    const m_down_right = LayerzAction{ .mouse_move = .{ .stepX = -10, .stepY = 10 } };

    var layer0 = PASSTHROUGH;
    map(&layer0, "W", m_up);
    map(&layer0, "D", m_down_right);

    var layout = [_]Layer{layer0};
    var keyboard = KeyboardState{ .layout = &layout, .writer = testing_write_event };
    keyboard.init();

    const inputs = [_]InputEvent{
        input_event(KEY_PRESS, "W", 0.0),
        input_event(KEY_RELEASE, "W", 0.1),
        input_event(KEY_PRESS, "D", 0.2),
        input_event(KEY_RELEASE, "D", 0.3),
    };
    for (inputs) |input| keyboard.handle(input);

    const expected = [_]InputEvent{
        _event(linux.EV_REL, linux.REL_X, 10, 0.0),
        _event(linux.EV_REL, linux.REL_Y, 0, 0.0),
        _event(linux.EV_REL, linux.REL_X, -10, 0.2),
        _event(linux.EV_REL, linux.REL_Y, 10, 0.2),
    };
    try std.testing.expectEqualSlices(InputEvent, &expected, test_outputs.items);
}

threadlocal var test_outputs: std.ArrayList(InputEvent) = undefined;
fn testing_write_event(event: InputEvent) void {
    // we are using fake timestamp for testing.
    _start_time = 0;
    // Skip the
    if (test_outputs.items.len == 0) {
        if (std.mem.eql(u8, std.mem.asBytes(&event), std.mem.asBytes(&sync_report)) or
            std.mem.eql(u8, std.mem.asBytes(&event), std.mem.asBytes(&_special_release_enter)))
            return;
    }
    test_outputs.append(event) catch unreachable;
}

/// Shortcut to create an InputEvent, using float for timestamp.
fn input_event(event: u8, comptime keyname: []const u8, time: f64) InputEvent {
    return .{
        .type = linux.EV_KEY,
        .value = event,
        .code = resolve(keyname),
        // The way time is stored actually depends of the compile target...
        // TODO: handle the case where sec and usec are part of the InputEvent struct.
        .time = linux_time(time),
    };
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
    try std.testing.expectEqual(
        InputEvent{
            .type = linux.EV_KEY,
            .value = 1,
            .code = linux.KEY_Q,
            .time = .{ .tv_sec = 123, .tv_usec = 456000 },
        },
        input_event(KEY_PRESS, "Q", 123.456),
    );
    try std.testing.expectEqual(
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
    try std.testing.expectEqual(@as(i32, 1), _input_delta_ms(123.456, 123.45701));
    try std.testing.expectEqual(@as(i32, 0), _input_delta_ms(123.456, 123.45650));
    try std.testing.expectEqual(@as(i32, -1), _input_delta_ms(123.45701, 123.456));
    try std.testing.expectEqual(@as(i32, 1000), _input_delta_ms(123, 124));
}

// Layout DSL: create a layer using the ANSI layout
pub fn ansi(
    number_row: [13]LayerzAction,
    top_row: [14]LayerzAction,
    middle_row: [13]LayerzAction,
    bottom_row: [12]LayerzAction,
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
