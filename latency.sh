LAPTOP_KEEB=/dev/input/by-path/platform-i8042-serio-0-event-kbd

KEEB=$LAPTOP_KEEB

set -ex

echo "release-safe"
zig build -Drelease-safe

sudo intercept -g $KEEB | zig-out/bin/latency
sudo intercept -g $KEEB | zig-out/bin/layerz | zig-out/bin/latency


echo "release-fast"
zig build -Drelease-fast

sudo intercept -g $KEEB | zig-out/bin/latency
sudo intercept -g $KEEB | zig-out/bin/layerz | zig-out/bin/latency
