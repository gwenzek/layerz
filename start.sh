KEYSEEBEE=/dev/input/by-id/usb-RIIR_Task_Force_Keyberon_0.2.0-event-kbd
LAPTOP_KEEB=/dev/input/by-path/platform-i8042-serio-0-event-kbd

DEVNODE=$KEYSEEBEE
DEVNODE=$LAPTOP_KEEB

zig build && \
  intercept -g $DEVNODE | zig-out/bin/layerz | uinput -d $DEVNODE
4
