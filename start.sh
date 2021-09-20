LAPTOP_KEEB=/dev/input/by-path/platform-i8042-serio-0-event-kbd

KEEB=$LAPTOP_KEEB

set -ex
zig build

intercept -g $KEEB | zig-out/bin/layerz | uinput -d $KEEB
