const layerz = @import("layerz.zig");
const std = @import("std");
const log = std.log;
const linux = layerz.linux;
const Action = layerz.Action;
const InputEvent = layerz.InputEvent;

pub fn KeyboardState(Provider: anytype) type {
    return struct {
        layout: []const layerz.Layer,
        event_provider: Provider,

        // This is the mutable state of the keyboard.
        // We are saving the current layer and the current layer for each key.
        // Every key release uses the layer at the time of the last press for this key.
        base_layer: u8 = 0,
        layer: u8 = 0,
        key_state: [layerz.NUM_KEYS]u8 = [_]u8{0} ** layerz.NUM_KEYS,

        const Self = @This();
        pub const DelayedHandler = fn (
            keyboard: *Self,
            event: InputEvent,
            next_event: InputEvent,
        ) void;

        pub fn init(self: *Self) void {
            // Release enter key. This is needed when you're launching ./layerz from a terminal
            // Apparently we need to delay the keyboard "grabbing" until after enter is released
            layerz._start_time = std.time.timestamp();
            layerz._special_release_enter = layerz.input_event(layerz.KEY_RELEASE, "ENTER", std.math.lossyCast(f64, layerz._start_time));
            self.writer(layerz._special_release_enter);
            self.writer(layerz.sync_report);

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
            if (input.type != linux.EV_KEY or input.code >= layerz.NUM_KEYS) {
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
        fn resolve_action(keyboard: *Self, input: InputEvent) Action {
            std.debug.assert(input.type == linux.EV_KEY);
            const key_layer = switch (input.value) {
                layerz.KEY_REPEAT, layerz.KEY_PRESS => keyboard.layer,
                layerz.KEY_RELEASE => keyboard.key_state[input.code],
                else => {
                    log.warn("ignoring unkown event {}", .{input});
                    return layerz.xx;
                },
            };

            keyboard.key_state[input.code] = key_layer;
            if (input.code == layerz.resolve("CAPSLOCK")) {
                log.debug("CAPSLOCK is on layer {}", .{key_layer});
            }
            return keyboard.layout[key_layer][input.code];
        }

        /// Handlers are allowed to consume more keyboard events that the one given to them.
        fn handle_action(keyboard: *Self, action: Action, input: InputEvent) void {
            // TODO: generate this switch ?
            switch (action) {
                .tap => |val| keyboard.handle_tap(val, input),
                .mod_tap => |val| keyboard.handle_mod_tap(val, input),
                .layer_toggle => |val| keyboard.handle_layer_toggle(val, input),
                .layer_hold => |val| keyboard.handle_layer_hold(val, input),
                .disabled => |val| keyboard.handle_disabled(val, input),
                .transparent => |val| keyboard.handle_transparent(val, input),
                .hook => |val| keyboard.handle_hook(val, input),
                .mouse_move => |val| keyboard.handle_mouse_move(val, input),
            }
        }

        fn handle_tap(keyboard: *Self, tap: Action.Tap, input: InputEvent) void {
            if (input.value == layerz.KEY_REPEAT) return;
            var output = input;
            output.code = tap.key;
            keyboard.writer(output);
        }

        /// Output two keys. This is useful for modifiers.
        // TODO: support more than one mod
        fn handle_mod_tap(keyboard: *Self, tap: Action.ModTap, input: InputEvent) void {
            if (input.value == layerz.KEY_REPEAT) return;
            var output = input;
            output.code = tap.key;
            var mod_press: InputEvent = output;
            mod_press.code = tap.mod;
            if (input.value == layerz.KEY_PRESS) {
                // First press the modifier then the key.
                keyboard.writer(mod_press);
                keyboard.writer(output);

                // Delay the modifier release to the next event
                var next_event = keyboard.read_event(0);
                var mod_release = mod_press;
                mod_release.value = layerz.KEY_RELEASE;
                keyboard.writer(mod_release);
                if (next_event) |next| keyboard.handle(next);
                return;
            } else {
                keyboard.writer(output);
            }
        }

        /// Switch between layers
        // TODO: could we have a startup check to see if we can get stuck on a layer ?
        fn handle_layer_toggle(keyboard: *Self, layer_toggle: Action.LayerToggle, event: InputEvent) void {
            switch (event.value) {
                layerz.KEY_PRESS => {
                    if (keyboard.layer != layer_toggle.layer) {
                        keyboard.layer = layer_toggle.layer;
                    } else {
                        keyboard.layer = keyboard.base_layer;
                    }
                },
                else => {},
            }
        }

        fn handle_layer_hold(self: *Self, layer_hold: Action.LayerHold, event: InputEvent) void {
            switch (event.value) {
                layerz.KEY_PRESS => {
                    var tap = event;
                    tap.code = layer_hold.key;
                    log.debug("Maybe we are holding a layer: {}. Delay tap: {}", .{ layer_hold.layer, event });

                    var disambiguated = false;
                    while (!disambiguated) {
                        disambiguated = self.disambiguate_layer_hold(layer_hold, tap);
                    }
                },
                layerz.KEY_RELEASE => {
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
            layer_hold: Action.LayerHold,
            tap: InputEvent,
        ) bool {
            var maybe_event = self.read_event(0);
            if (maybe_event == null) return true;
            const event = maybe_event.?;

            if (layer_hold.key == event.code) {
                // Another event on the layer key
                if (event.value == layerz.KEY_RELEASE) {
                    if (layerz.delta_ms(tap, event) < layer_hold.delay_ms) {
                        // We have just tapped on the layer button, emit the tap and release
                        log.debug("Quick tap on layer {})", .{layer_hold});
                        self.writer(tap);
                        self.handle_tap(.{ .key = layer_hold.key }, event);
                    } else {
                        // We have been holding for a long time, do nothing
                    }
                    return true;
                } else {
                    // This is probably a layerz.KEY_REPEAT of the hold key, let's wait for another key
                    return false;
                }
            } else {
                if (event.value == layerz.KEY_PRESS) {
                    // TODO: handle quick typing ?
                    // if (delta_ms(tap, event) > layer_hold.delay_ms) ...
                    log.debug("Holding layer {}", .{layer_hold});
                    self.layer = layer_hold.layer;
                }
                // Call regular key handling code with the new layer
                self.handle(event);
                // Continue the while loop while we haven't found a key_press
                return event.value == layerz.KEY_PRESS;
            }
        }

        /// Do nothing.
        fn handle_disabled(keyboard: *const Self, layer_hold: Action.Disabled, event: InputEvent) void {
            _ = keyboard;
            _ = layer_hold;
            _ = event;
        }

        /// Do the action from the base layer instead.
        /// If we are already on the base layer, just forward the input event.
        fn handle_transparent(keyboard: *Self, transparent: Action.Transparent, event: InputEvent) void {
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

        fn handle_hook(keyboard: *Self, hook: Action.Hook, input: InputEvent) void {
            _ = keyboard;
            if (input.value != layerz.KEY_PRESS) return;

            hook.f() catch |err| {
                log.err("Custom hook {} failed with {}", .{ hook.f, err });
                return;
            };
        }

        fn handle_mouse_move(keyboard: *Self, mouse_move: Action.MouseMove, input: InputEvent) void {
            if (input.value == layerz.KEY_RELEASE) return;
            var output = input;
            output.type = linux.EV_REL;
            output.code = mouse_move.key;
            switch (mouse_move.key) {
                linux.REL_X => {
                    if (mouse_move.stepX != 0) {
                        output.code = linux.REL_X;
                        output.value = mouse_move.stepX;
                        keyboard.writer(output);
                    }
                    if (mouse_move.stepY != 0) {
                        output.code = linux.REL_Y;
                        output.value = mouse_move.stepY;
                        keyboard.writer(output);
                    }
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
