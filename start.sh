LAPTOP_KEEB=/dev/input/by-path/platform-i8042-serio-0-event-kbd

KEEB=$LAPTOP_KEEB

set -ex
# zig build -Drelease-safe
zig build

sudo intercept -g $KEEB | zig-out/bin/layerz | sudo uinput -d $KEEB
