const std = @import("std");
const io = std.io;
const math = std.math;
const linux = @cImport({
    @cInclude("linux/input.h");
});
const InputEvent = linux.input_event;

const InputEventVal = enum {
    PRESS = 1,
    RELEASE = 0,
    REPEAT = 2,
};

const LayerzActionKind = enum {
    tap,
    mod_tap, // Tap with a modifier
    layer_hold,
    layer_toggle,
};

const LayerzActionTap = struct { key: u8 };
const LayerzActionModTap = struct { key: u8, mod: u8 };
const LayerzActionLayerHold = struct { key: u8, layer: u8, delay_ms: u16 = 200 };
const LayerzActionLayerToggle = struct { layer: u8 };
// TODO: add "transparent" and "disabled" actions

const LayerzAction = union(LayerzActionKind) {
    tap: LayerzActionTap,
    mod_tap: LayerzActionModTap,
    layer_hold: LayerzActionLayerHold,
    layer_toggle: LayerzActionLayerToggle,
};

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

// const KeyState = enum {
//     RELEASED,
//     PRESSED,
//     TAPPED,
//     DOUBLETAPPED,
//     CONSUMED,
// };
// void
// syn_pause() {
//     static const struct input_event syn = {
//         .type = EV_SYN,
//         .code = SYN_REPORT,
//         .value = 0,
//     };
//     static struct timespec p = { .tv_sec = 0, .tv_nsec = 0 };
//     if (!p.tv_nsec)
//             p.tv_nsec = cfg.synthetic_keys_pause_millis * 1e6;

//     write_event(&syn);
//     nanosleep(&p, &p);
// }

const LayerzEventKind = enum {
    NONE,
    MAYBE_LAYER,
    LAYER_ON,
    MAYBE_DOUBLE_tap,
};

const LayerzEvent = struct {
    key: u8,
    layer: u8,
    kind: LayerzEventKind,
    timestamp: u32,
    timestamp_ms: u16,
};

const PASSTHROUGH = init: {
    var initial_value: [256]LayerzAction = undefined;
    for (initial_value) |*action, i| {
        action.* = LayerzAction{ .tap = .{ .key = i } };
    }
    break :init initial_value;
};

const EventWriter = fn (event: *const InputEvent) void;

const KeyboardState = struct {
    layout: []const [256]LayerzAction,
    writer: EventWriter,

    base_layer: u8 = 0,
    layer: u8 = 0,
    _events_buffer: [16]LayerzEvent = undefined,
    events: std.ArrayListUnmanaged(LayerzEvent) = undefined,

    const Self = @This();

    fn init(self: *Self) void {
        self.events = .{
            .items = self._events_buffer[0..0],
            .capacity = self._events_buffer.len,
        };
    }

    // void
    // tap(KeyboardState *m, unsigned int32 value) {
    //     static struct input_event input = { .type = EV_KEY, };
    //     Tap *t;

    //     input.value = value;
    //     for (t = m->tap; t; t = t->n) {
    //         input.code = t->code;
    //         writer(&input);
    //         if (t->n)
    //             syn_pause();
    //     }
    // }

    // void
    // hold(KeyboardState *m, unsigned int32 value) {
    //     static struct input_event input = { .type = EV_KEY, };
    //     Hold *h;

    //     input.value = value;
    //     for (h = m->hold; h; h = h->n) {
    //         input.code = h->code;
    //         writer(&input);
    //         if (h->n)
    //             syn_pause();
    //     }
    // }

    fn handle(keyboard: *Self, input: *const InputEvent) void {
        // // consume all taps that are incomplete
        // if (input.value == @enumToInt(InputEventVal.PRESS))
        //     keyboard.consume_pressed();

        switch (input.value) {
            // TODO: I don't think this API make sense, we should switch on action type
            @enumToInt(InputEventVal.PRESS) => keyboard.handle_press(input),
            @enumToInt(InputEventVal.RELEASE) => keyboard.handle_press(input),
            // linux console, X, wayland handles repeat
            @enumToInt(InputEventVal.REPEAT) => {},
            else => std.log.warn("unexpected .value={d} .code={d}, doing nothing", .{ input.value, input.code }),
        }
    }

    fn handle_press(keyboard: *Self, event: *const InputEvent) void {
        const action = keyboard.layout[keyboard.layer][event.code];
        switch (action) {
            LayerzActionKind.tap => |tap| {
                var new_event = event.*;
                new_event.code = tap.key;
                keyboard.writer(&new_event);
            },
            LayerzActionKind.mod_tap => |tap| {
                var new_event = event.*;
                new_event.code = tap.key;
                var mod_event = event.*;
                mod_event.code = tap.mod;
                if (event.value == @enumToInt(InputEventVal.PRESS)) {
                    // First press the modifier then the key.
                    // TODO: should we modify timestamps ?
                    keyboard.writer(&mod_event);
                    keyboard.writer(&new_event);
                } else if (event.value == @enumToInt(InputEventVal.RELEASE)) {
                    // First release the key then the modifier.
                    keyboard.writer(&new_event);
                    keyboard.writer(&mod_event);
                }
            },
            LayerzActionKind.layer_toggle => |layer_toggle| {
                switch (event.value) {
                    @enumToInt(InputEventVal.RELEASE) => {
                        if (keyboard.layer != layer_toggle.layer) {
                            keyboard.layer = layer_toggle.layer;
                        } else {
                            keyboard.layer = keyboard.base_layer;
                        }
                    },
                    else => {},
                }
            },
            else => keyboard.writer(event),
        }
    }

    fn loop(keyboard: *Self) void {
        var input: InputEvent = undefined;

        while (read_event(&input)) {
            if (input.type == linux.EV_MSC and input.code == linux.MSC_SCAN)
                continue;

            // make mouse and touchpad events consume pressed taps
            if (input.type == linux.EV_REL or input.type == linux.EV_ABS)
                keyboard.consume_pressed();

            // forward anything that is not a key event, including SYNs
            if (input.type != linux.EV_KEY) {
                writer(&input);
                continue;
            }

            keyboard.handle(&input);
        }
    }

    // void
    // print_usage(FILE *stream, const char *program) {
    //     fprintf(stream,
    //             "dual-function-keys plugin for interception tools:\n"
    //             "        https://gitlab.com/interception/linux/tools\n"
    //             "\n"
    //             "usage: %s [-v] [-h] -c /path/to/cfg.yaml\n"
    //             "\n"
    //             "options:\n"
    //             "    -v                     show version and exit\n"
    //             "    -h                     show this message and exit\n"
    //             "    -c /path/to/cfg.yaml   use cfg.yaml\n",
    //             program);
    // }
};

fn read_event(event: *InputEvent) bool {
    const buffer = std.mem.asBytes(event);
    const ret = io.getStdIn().read(buffer) catch std.debug.panic("Couldn't read event from stdin", .{});
    return ret > 0;
}

fn write_event_to_stdout(event: *const InputEvent) void {
    const buffer = std.mem.asBytes(event);
    _ = io.getStdOut().write(buffer) catch std.debug.panic("Couldn't write event {s} to stdout", .{event});
}

// int32
// main(int32 argc, char *argv[]) {
//     setbuf(stdin, NULL), setbuf(stdout, NULL);

//     int32 configured = 0;
//     int32 opt;
//     while ((opt = getopt(argc, argv, "vhc:")) != -1) {
//         switch (opt) {
//             case 'v':
//                 return fprintf(stdout, "dual-function-keys version %s\n", VERSION), EXIT_SUCCESS;
//             case 'h':
//                 return print_usage(stdout, argv[0]), EXIT_SUCCESS;
//             case 'c':
//                 if (configured)
//                     break;
//                 read_cfg(&cfg, optarg);
//                 configured = 1;
//                 continue;
//         }
//     }

//     if (!configured)
//         return print_usage(stderr, argv[0]), EXIT_FAILURE;

//     loop();
// }

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = &general_purpose_allocator.allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    std.log.info("All your codebase are belong to us.", .{});

    const layout = [_][256]LayerzAction{PASSTHROUGH};
    var keyboard = KeyboardState(layout.len, layout, write_event_to_stdout){};
    keyboard.init(gpa);
    defer keyboard.deinit(gpa);
    keyboard.loop();
}

// TODO: how can we avoid the global variable ?
var test_outputs: std.ArrayList(InputEvent) = undefined;
fn testing_write_event(event: *const InputEvent) void {
    test_outputs.append(event.*) catch unreachable;
}

/// Shortcut to create an InputEvent, using float for timestamp.
fn input_event(event: InputEventVal, comptime keyname: []const u8, time: f64) InputEvent {
    const seconds = math.lossyCast(u32, time);
    const micro_seconds = math.lossyCast(u32, (time - math.lossyCast(f64, seconds)) * 1000_000);
    return .{
        .type = linux.EV_KEY,
        .value = @enumToInt(event),
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
        input_event(InputEventVal.PRESS, "Q", 123.456),
    );
}

test "PASSTHROUGH layout passes all keyboard events through" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();
    const layout = [_][256]LayerzAction{PASSTHROUGH};
    var keyboard = KeyboardState{ .layout = &layout, .writer = testing_write_event };
    keyboard.init();

    const events = [_]InputEvent{
        input_event(InputEventVal.PRESS, "Q", 0),
        input_event(InputEventVal.RELEASE, "Q", 0.1),
    };
    for (events) |*event| keyboard.handle(event);

    try std.testing.expectEqualSlices(InputEvent, &events, test_outputs.items);
}

test "Simple key remap" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();

    var layer: [256]LayerzAction = PASSTHROUGH;
    // Map key "Q" to "A"
    layer[resolve("Q")] = k("A");

    var layout = [_][256]LayerzAction{layer};
    var keyboard = KeyboardState{ .layout = &layout, .writer = testing_write_event };
    keyboard.init();

    const inputs = [_]InputEvent{
        input_event(InputEventVal.PRESS, "Q", 0),
        input_event(InputEventVal.RELEASE, "Q", 0.1),
    };
    for (inputs) |*event| keyboard.handle(event);

    const expected = [_]InputEvent{
        input_event(InputEventVal.PRESS, "A", 0),
        input_event(InputEventVal.RELEASE, "A", 0.1),
    };
    try std.testing.expectEqualSlices(InputEvent, &expected, test_outputs.items);
}

test "Key remap with modifier" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();

    var layer: [256]LayerzAction = PASSTHROUGH;
    // Map "Q" to "(" (shit+9)
    layer[resolve("Q")] = s("9");

    var layout = [_][256]LayerzAction{layer};
    var keyboard = KeyboardState{ .layout = &.{layer}, .writer = testing_write_event };
    keyboard.init();

    const inputs = [_]InputEvent{
        input_event(InputEventVal.PRESS, "Q", 0),
        input_event(InputEventVal.RELEASE, "Q", 0.1),
    };
    for (inputs) |*event| keyboard.handle(event);

    const expected = [_]InputEvent{
        input_event(InputEventVal.PRESS, "LEFTSHIFT", 0),
        input_event(InputEventVal.PRESS, "9", 0),
        input_event(InputEventVal.RELEASE, "9", 0.1),
        input_event(InputEventVal.RELEASE, "LEFTSHIFT", 0.1),
    };
    try std.testing.expectEqualSlices(InputEvent, &expected, test_outputs.items);
}

test "Layer toggle" {
    test_outputs = std.ArrayList(InputEvent).init(std.testing.allocator);
    defer test_outputs.deinit();

    var layer0: [256]LayerzAction = PASSTHROUGH;
    var layer1: [256]LayerzAction = PASSTHROUGH;
    // On both layers: map tab to toggle(layer1)
    layer0[resolve("TAB")] = lt(1);
    layer1[resolve("TAB")] = lt(1);
    // On second layer: map key "Q" to "A"
    layer1[resolve("Q")] = k("A");

    var layout = [_][256]LayerzAction{ layer0, layer1 };
    var keyboard = KeyboardState{ .layout = &layout, .writer = testing_write_event };
    keyboard.init();

    const inputs = [_]InputEvent{
        // layer 0
        input_event(InputEventVal.PRESS, "Q", 0),
        input_event(InputEventVal.RELEASE, "Q", 0.1),
        input_event(InputEventVal.PRESS, "TAB", 0.2),
        input_event(InputEventVal.RELEASE, "TAB", 0.3),
        // layer 1
        input_event(InputEventVal.PRESS, "Q", 0.4),
        input_event(InputEventVal.RELEASE, "Q", 0.5),
        input_event(InputEventVal.PRESS, "TAB", 0.6),
        input_event(InputEventVal.RELEASE, "TAB", 0.7),
        // back to layer 0
        input_event(InputEventVal.PRESS, "Q", 0.8),
        input_event(InputEventVal.RELEASE, "Q", 0.9),
    };
    for (inputs) |*event| keyboard.handle(event);

    const expected = [_]InputEvent{
        input_event(InputEventVal.PRESS, "Q", 0),
        input_event(InputEventVal.RELEASE, "Q", 0.1),
        input_event(InputEventVal.PRESS, "A", 0.4),
        input_event(InputEventVal.RELEASE, "A", 0.5),
        input_event(InputEventVal.PRESS, "Q", 0.8),
        input_event(InputEventVal.RELEASE, "Q", 0.9),
    };
    try std.testing.expectEqualSlices(InputEvent, &expected, test_outputs.items);

    // TODO: decide how to handle interleaving combos
    // input_event(InputEventVal.PRESS, "Q", 0.4),
    // input_event(InputEventVal.PRESS, "TAB", 0.5),
    // input_event(InputEventVal.RELEASE, "TAB", 0.6),
    // input_event(InputEventVal.RELEASE, "Q", 0.7),
}
