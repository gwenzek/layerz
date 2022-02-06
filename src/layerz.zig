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

var _start_time: i64 = -1;
var _start_time_ns: i64 = 0;
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
                    try std.fmt.format(writer, "{{ EV_KEY({d}, {d}) ({d:.3}) }}", .{ input.value, input.code, time });
                    return;
                },
            };
            try std.fmt.format(writer, "{{{s}({s}) ({d:.3})}}", .{ value, resolveName(input.code), time });
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

    try testing.expectEqualSlices(
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
    beep,
    hook,
};

pub const LayerzActionTap = struct { key: u8 };
pub const LayerzActionModTap = struct { key: u8, mod: u8 };
pub const LayerzActionLayerHold = struct { key: u8, layer: u8, delay_ms: u16 = 200 };
pub const LayerzActionLayerToggle = struct { layer: u8 };
pub const LayerzActionDisabled = struct {};
pub const LayerzActionTransparent = struct {};
pub const LayerzActionBeep = struct {};
pub const LayerzActionHook = struct { f: fn () anyerror!void };
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
    beep: LayerzActionBeep,
    hook: LayerzActionHook,
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

const _keynames = [_][]const u8{ "TAB", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "ENTER", "LCTRL", "A", "S", "D", "F", "G", "H" };
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
/// Used to indicate buffer overrun in the evdev client’s event queue.
/// Client should ignore all events up to and including next SYN_REPORT event
/// and query the device (using EVIOCG* ioctls) to obtain its current state.
const sync_dropped = InputEvent{
    .type = linux.EV_SYN,
    .code = linux.SYN_DROPPED,
    .value = 0,
    .time = undefined,
};

var _special_release_enter: InputEvent = undefined;

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

pub fn stdioKeyboard(layout: []const Layer) KeyboardState(providers.EvdevProvider) {
    const provider = providers.EvdevProvider.init("/dev/input/by-path/platform-i8042-serio-0-event-kbd") catch |err| std.debug.panic("can't open device {}", .{err});
    var keeb = KeyboardState(providers.EvdevProvider){
        .layout = layout,
        .event_provider = provider,
    };
    keeb.init();
    return keeb;
}

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

pub fn KeyboardState(Provider: anytype) type {
    return struct {
        layout: []const Layer,
        event_provider: Provider,

        // This is the mutable state of the keyboard.
        // We are saving the current layer and the current layer for each key.
        // Every key release uses the layer at the time of the last press for this key.
        base_layer: u8 = 0,
        layer: u8 = 0,
        key_state: [NUM_KEYS]u8 = [_]u8{0} ** NUM_KEYS,

        const Self = @This();
        pub const DelayedHandler = fn (
            keyboard: *Self,
            event: InputEvent,
            next_event: InputEvent,
        ) void;

        pub fn init(self: *Self) void {
            // Release enter key. This is needed when you're launching ./layerz from a terminal
            // Apparently we need to delay the keyboard "grabbing" until after enter is released
            _start_time = std.time.timestamp();
            _special_release_enter = input_event(KEY_RELEASE, "ENTER", std.math.lossyCast(f64, _start_time));
            self.writer(_special_release_enter);
            self.writer(sync_report);

            // TODO: should we resolve the transparent actions now ?
        }

        pub fn deinit(self: *Self) void {
            self.event_provider.deinit();
        }

        pub fn handle(keyboard: *Self, input: InputEvent) void {
            if (input.type == linux.EV_MSC and input.code == linux.MSC_SCAN) {
                keyboard.writer(input);
                return;
            }

            // forward anything that is not a key event, including sync events
            if (input.type != linux.EV_KEY or input.code >= NUM_KEYS) {
                keyboard.writer(input);
                return;
            }
            log.debug("read {}", .{input});

            const action = keyboard.resolve_action(input);
            keyboard.handle_action(action, input);
        }

        /// Get the layer on which the event happened.
        /// Key presses happen on the current layer,
        /// While key releases happen on the layer at the time of the press.
        fn resolve_action(keyboard: *Self, input: InputEvent) LayerzAction {
            const key_layer = switch (input.value) {
                KEY_REPEAT => {
                    // TODO: check if it's right to swallow repeats event
                    // linux console, X, wayland handles repeat
                    return xx;
                },
                KEY_PRESS => keyboard.layer,
                KEY_RELEASE => keyboard.key_state[input.code],
                else => {
                    log.warn("ignoring unkown event {}", .{input});
                    return xx;
                },
            };

            keyboard.key_state[input.code] = key_layer;
            if (input.code == resolve("CAPSLOCK")) {
                log.debug("CAPSLOCK is on layer {}", .{key_layer});
            }
            return keyboard.layout[key_layer][input.code];
        }

        /// Handlers are allowed to consume more keyboard events that the one given to them.
        fn handle_action(keyboard: *Self, action: LayerzAction, input: InputEvent) void {
            // TODO: generate this switch ?
            switch (action) {
                .tap => |val| keyboard.handle_tap(val, input),
                .mod_tap => |val| keyboard.handle_mod_tap(val, input),
                .layer_toggle => |val| keyboard.handle_layer_toggle(val, input),
                .layer_hold => |val| keyboard.handle_layer_hold(val, input),
                .disabled => |val| keyboard.handle_disabled(val, input),
                .transparent => |val| keyboard.handle_transparent(val, input),
                .beep => |val| keyboard.handle_beep(val, input),
                .hook => |val| keyboard.handle_hook(val, input),
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

                // Delay the modifier release to the next event
                var next_event = keyboard.read_event(0);
                var mod_release = mod_press;
                mod_release.value = KEY_RELEASE;
                keyboard.writer(mod_release);
                if (next_event) |next| keyboard.handle(next);
                return;
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

        fn handle_layer_hold(self: *Self, layer_hold: LayerzActionLayerHold, event: InputEvent) void {
            switch (event.value) {
                KEY_PRESS => {
                    var tap = event;
                    tap.code = layer_hold.key;
                    log.debug("Maybe we are holding a layer: {}. Delay tap: {}", .{ layer_hold.layer, event });

                    var disambiguated = false;
                    while (!disambiguated) {
                        disambiguated = self.disambiguate_layer_hold(layer_hold, tap);
                    }
                },
                KEY_RELEASE => {
                    if (self.layer == layer_hold.layer) {
                        log.debug("Disabling layer: {} on {}", .{ layer_hold.layer, event });
                        self.layer = self.base_layer;
                    } else {
                        self.handle_tap(.{ .key = layer_hold.key }, event);
                    }
                },
                else => {},
            }
        }

        fn disambiguate_layer_hold(
            self: *Self,
            layer_hold: LayerzActionLayerHold,
            tap: InputEvent,
        ) bool {
            var maybe_event = self.read_event(0);
            if (maybe_event == null) return true;
            const event = maybe_event.?;

            if (layer_hold.key == event.code) {
                // Another event on the layer key
                if (event.value == KEY_RELEASE) {
                    if (delta_ms(tap, event) < layer_hold.delay_ms) {
                        // We have just tapped on the layer button, emit the tap and release
                        log.debug("Quick tap on layer {})", .{layer_hold});
                        self.writer(tap);
                        self.handle_tap(.{ .key = layer_hold.key }, event);
                    } else {
                        // We have been holding for a long time, do nothing
                    }
                    return true;
                } else {
                    // This is probably a KEY_REPEAT of the hold key, let's wait for another key
                    return false;
                }
            } else {
                if (event.value == KEY_PRESS) {
                    // TODO: handle quick typing ?
                    // if (delta_ms(tap, event) > layer_hold.delay_ms) ...
                    log.debug("Holding layer {}", .{layer_hold});
                    self.layer = layer_hold.layer;
                }
                // Call regular key handling code with the new layer
                const next_action = self.resolve_action(event);
                self.handle_action(next_action, event);
                // Continue the while loop while we haven't found a key_press
                return event.value == KEY_PRESS;
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

        fn handle_beep(keyboard: *Self, beep: LayerzActionBeep, input: InputEvent) void {
            if (!@hasDecl(Provider, "beep")) return;
            if (input.value != KEY_PRESS) return;

            _ = beep;
            @field(Provider, "beep")(&keyboard.event_provider);
        }

        fn handle_hook(keyboard: *Self, hook: LayerzActionHook, input: InputEvent) void {
            _ = keyboard;
            if (input.value != KEY_PRESS) return;

            hook.f() catch |err| {
                log.err("Custom hook {} failed with {}", .{ hook.f, err });
                return;
            };
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
            while (keyboard.read_event(0)) |input| {
                keyboard.handle(input);
            }
            log.debug("No more event, clearing the queue", .{});
        }

        pub fn writer(keyboard: *Self, event: InputEvent) void {
            return keyboard.event_provider.write_event(event);
        }

        pub fn read_event(keyboard: *Self, timeout_ms: u32) ?InputEvent {
            return keyboard.event_provider.read_event(timeout_ms);
        }
    };
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
    const m_up = LayerzAction{ .mouse_move = .{ .stepX = 10 } };
    const m_down_right = LayerzAction{ .mouse_move = .{ .stepX = -10, .stepY = 10 } };

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
        _event(linux.EV_REL, linux.REL_Y, 0, 0.0),
        _event(linux.EV_REL, linux.REL_X, -10, 0.2),
        _event(linux.EV_REL, linux.REL_Y, 10, 0.2),
    };
    try testing.expectEqualSlices(InputEvent, &expected, keyboard.event_provider.outputs.items);
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
