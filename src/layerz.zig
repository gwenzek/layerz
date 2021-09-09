/// Reference https://www.kernel.org/doc/html/v4.15/input/event-codes.html
const std = @import("std");
const io = std.io;
const math = std.math;
const linux = @cImport({
    @cInclude("linux/input.h");
});
const InputEvent = linux.input_event;

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
};

const LayerzActionTap = struct { key: u8 };
const LayerzActionModTap = struct { key: u8, mod: u8 };
const LayerzActionLayerHold = struct { key: u8, layer: u8, delay_ms: u16 = 200 };
const LayerzActionLayerToggle = struct { layer: u8 };
const LayerzActionDisabled = struct {};
const LayerzActionTransparent = struct {};
// TODO: add "transparent" and "disabled" actions

pub const LayerzAction = union(LayerzActionKind) {
    tap: LayerzActionTap,
    mod_tap: LayerzActionModTap,
    layer_hold: LayerzActionLayerHold,
    layer_toggle: LayerzActionLayerToggle,
    disabled: LayerzActionDisabled,
    transparent: LayerzActionTransparent,
};

pub const Layerz = [256]LayerzAction;

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

test "Layout DSL: k" {
    try std.testing.expectEqual(linux.KEY_Q, k("Q").tap.key);
    try std.testing.expectEqual(linux.KEY_TAB, k("TAB").tap.key);
}

/// Layout DSL: tap shift and the given key
pub fn s(comptime keyname: []const u8) LayerzAction {
    return .{
        .mod_tap = .{ .key = resolve(keyname), .mod = linux.KEY_LEFTSHIFT },
    };
}

test "Layout DSL: s" {
    try std.testing.expectEqual(linux.KEY_EQUAL, s("EQUAL").mod_tap.key);
    try std.testing.expectEqual(linux.KEY_LEFTSHIFT, s("EQUAL").mod_tap.mod);
}

pub fn lt(layer: u8) LayerzAction {
    return .{
        .layer_toggle = .{ .layer = layer },
    };
}

pub const x: LayerzAction = .{ .disabled = .{} };
pub const trans: LayerzAction = .{ .transparent = .{} };

pub const PASSTHROUGH: Layerz = [_]LayerzAction{trans} ** 256;

pub fn map(layer: *Layerz, comptime src_key: []const u8, action: LayerzAction) void {
    layer[resolve(src_key)] = action;
}

// TODO: understand when we need to send "syn" events
const syn_pause = InputEvent{
    .type = linux.EV_SYN,
    .code = linux.SYN_REPORT,
    .value = 0,
    .time = undefined,
};

pub const EventWriter = fn (event: *const InputEvent) void;

pub const KeyboardState = struct {
    layout: []const [256]LayerzAction,
    writer: EventWriter = write_event_to_stdout,

    base_layer: u8 = 0,
    layer: u8 = 0,
    _stack_buffer: [32 * @sizeOf(InputEvent)]u8 = undefined,
    stack: std.ArrayListUnmanaged(InputEvent) = undefined,

    const Self = @This();

    pub fn init(self: *Self) void {
        var alloc = std.heap.FixedBufferAllocator.init(&self._stack_buffer);
        self.stack = std.ArrayListUnmanaged(InputEvent){};
        self.stack.ensureTotalCapacity(&alloc.allocator, 16) catch unreachable;
    }

    pub fn handle(keyboard: *Self, input: *const InputEvent) void {
        if (input.type == linux.EV_MSC and input.code == linux.MSC_SCAN)
            return;

        // make mouse and touchpad events consume pressed taps
        // if (input.type == linux.EV_REL or input.type == linux.EV_ABS)
        //     keyboard.consume_pressed();

        // forward anything that is not a key event, including SYNs
        if (input.type != linux.EV_KEY) {
            keyboard.writer(input);
            return;
        }

        // consume all taps that are incomplete
        if (input.value == KEY_PRESS)
            keyboard.consume_pressed();

        if (input.value == KEY_REPEAT) {
            // TODO: check if it's right to swallow repeats event
            // linux console, X, wayland handles repeat
            return;
        }
        if (input.value != KEY_PRESS and input.value != KEY_RELEASE and input.value != KEY_REPEAT) {
            std.log.warn("unexpected .value={d} .code={d}, doing nothing", .{ input.value, input.code });
            return;
        }
        const action = keyboard.layout[keyboard.layer][input.code];
        keyboard.handle_action(action, input);
    }

    fn handle_action(keyboard: *Self, action: LayerzAction, input: *const InputEvent) void {
        // TODO: generate this switch ?
        switch (action) {
            .tap => |val| keyboard.handle_tap(val, input),
            .mod_tap => |val| keyboard.handle_mod_tap(val, input),
            .layer_toggle => |val| keyboard.handle_layer_toggle(val, input),
            .layer_hold => |val| keyboard.handle_layer_hold(val, input),
            .disabled => |val| keyboard.handle_disabled(val, input),
            .transparent => |val| keyboard.handle_transparent(val, input),
        }
    }

    fn handle_tap(keyboard: *Self, tap: LayerzActionTap, input: *const InputEvent) void {
        var output = input.*;
        output.code = tap.key;
        keyboard.writer(&output);
        std.log.debug("({d}-{d})->({d}-{d})", .{ input.code, input.value, output.code, output.value });
    }

    /// Output two keys. This is useful for modifiers.
    // TODO: support more than one mod
    fn handle_mod_tap(keyboard: *Self, tap: LayerzActionModTap, input: *const InputEvent) void {
        var output = input.*;
        output.code = tap.key;
        var mod_press: InputEvent = output;
        mod_press.code = tap.mod;
        if (input.value == KEY_PRESS) {
            // First press the modifier then the key.
            keyboard.writer(&mod_press);
            keyboard.writer(&output);

            // Delay the modifier release to the next key press.
            var mod_release = keyboard.stack.addOneAssumeCapacity();
            mod_release.* = mod_press;
            mod_release.value = KEY_RELEASE;
        } else if (input.value == KEY_RELEASE) {
            keyboard.writer(&output);
            var i = @intCast(u8, keyboard.stack.items.len);
            // Release the mod if it hasn't been done before.
            while (i > 0) : (i -= 1) {
                var mod_release = keyboard.stack.items[i - 1];
                if (mod_release.code == tap.mod) {
                    keyboard.writer(&mod_release);
                    _ = keyboard.stack.orderedRemove(i - 1);
                }
            }
        } else {
            keyboard.writer(&output);
        }
    }

    /// Switch between layers
    // TODO: could we have a startup check to see if we can get stuck on a layer ?
    fn handle_layer_toggle(keyboard: *Self, layer_toggle: LayerzActionLayerToggle, event: *const InputEvent) void {
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

    fn handle_layer_hold(keyboard: *Self, layer_hold: LayerzActionLayerHold, event: *const InputEvent) void {
        keyboard.writer(event);
        // TODO: implement layer_hold
    }

    /// Do nothing.
    fn handle_disabled(keyboard: *Self, layer_hold: LayerzActionDisabled, event: *const InputEvent) void {}

    /// Do the action from the base layer instead.
    /// If we are already on the base layer, just forward the input event.
    fn handle_transparent(keyboard: *Self, transparent: LayerzActionTransparent, event: *const InputEvent) void {
        std.log.debug("({d}-{d})", .{ event.code, event.value });
        if (keyboard.layer == keyboard.base_layer) {
            keyboard.writer(event);
        } else {
            const action = keyboard.layout[keyboard.base_layer][event.code];
            switch (action) {
                // We need to handle transparent explicitly otherwise we create an infinite loop.
                .transparent => keyboard.writer(event),
                else => keyboard.handle_action(action, event),
            }
        }
    }

    /// Read events from stdinput and handle them.
    pub fn loop(keyboard: *Self) void {
        var input: InputEvent = undefined;
        const buffer = std.mem.asBytes(&input);
        while (io.getStdIn().read(buffer)) {
            keyboard.handle(&input);
        } else |err| {
            std.debug.panic("Couldn't read event from stdin", .{});
        }
    }

    pub fn consume_pressed(keyboard: *KeyboardState) void {
        while (keyboard.stack.items.len > 0) {
            var delayed_event = keyboard.stack.pop();
            keyboard.writer(&delayed_event);
        }
    }
};

pub fn write_event_to_stdout(event: *const InputEvent) void {
    const buffer = std.mem.asBytes(event);
    _ = io.getStdOut().write(buffer) catch std.debug.panic("Couldn't write event {s} to stdout", .{event});
}

test "Key remap with modifier" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();

    var layer: [256]LayerzAction = PASSTHROUGH;
    // Map "Q" to "(" (shift+9)
    map(&layer, "Q", s("9"));

    var layout = [_][256]LayerzAction{layer};
    var keyboard = KeyboardState{ .layout = &.{layer}, .writer = testing_write_event };
    keyboard.init();

    const inputs = [_]InputEvent{
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_RELEASE, "Q", 0.1),
    };
    for (inputs) |*event| keyboard.handle(event);

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

    var layer: [256]LayerzAction = PASSTHROUGH;
    // Map "Q" to "(" (shift+9)
    map(&layer, "Q", s("9"));

    var layout = [_][256]LayerzAction{layer};
    var keyboard = KeyboardState{ .layout = &.{layer}, .writer = testing_write_event };
    keyboard.init();

    const inputs = [_]InputEvent{
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_PRESS, "W", 0.1),
        input_event(KEY_RELEASE, "W", 0.2),
        input_event(KEY_RELEASE, "Q", 0.3),
    };
    for (inputs) |*event| keyboard.handle(event);

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

    var layout = [_]Layerz{ layer0, layer1 };
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
    for (inputs) |*event| keyboard.handle(event);

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

test "PASSTHROUGH layout passes all keyboard events through" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();
    const layout = [_]Layerz{PASSTHROUGH};
    var keyboard = KeyboardState{ .layout = &layout, .writer = testing_write_event };
    keyboard.init();

    const inputs = [_]InputEvent{
        input_event(KEY_PRESS, "Q", 0.0),
        input_event(KEY_RELEASE, "Q", 0.1),
    };
    for (inputs) |*event| keyboard.handle(event);

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
    map(&layer1, "Q", trans);
    map(&layer1, "W", k("W"));

    var layout = [_]Layerz{ layer0, layer1 };
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
    for (inputs) |*event| keyboard.handle(event);

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

// TODO: how can we avoid the global variable ?
//
var test_outputs: std.ArrayList(InputEvent) = undefined;
fn testing_write_event(event: *const InputEvent) void {
    test_outputs.append(event.*) catch unreachable;
}

/// Shortcut to create an InputEvent, using float for timestamp.
fn input_event(event: u8, comptime keyname: []const u8, time: f64) InputEvent {
    const seconds = math.lossyCast(u32, time);
    const micro_seconds = math.lossyCast(u32, (time - math.lossyCast(f64, seconds)) * 1000_000);
    return .{
        .type = linux.EV_KEY,
        .value = event,
        .code = resolve(keyname),
        // The way time is stored actually depends of the compile target...
        // TODO: handle the case where sec and usec are part of the InputEvent struct.
        .time = .{ .tv_sec = seconds, .tv_usec = micro_seconds },
    };
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
}
