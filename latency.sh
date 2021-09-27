LAPTOP_KEEB=/dev/input/by-path/platform-i8042-serio-0-event-kbd

KEEB=$LAPTOP_KEEB

set -e

[[ ! -d zig-out ]] || rm -r zig-out/

echo  "*** release-safe ***"
zig build -Drelease-safe

echo " - intercept only"
sudo intercept -g $KEEB | zig-out/bin/latency
echo " - intercept + layerz"
sudo intercept -g $KEEB | zig-out/bin/layerz | zig-out/bin/latency


echo "*** release-fast ***"
zig build -Drelease-fast

echo " - intercept only"
sudo intercept -g $KEEB | zig-out/bin/latency
echo " - intercept + layerz"
sudo intercept -g $KEEB | zig-out/bin/layerz | zig-out/bin/latency
