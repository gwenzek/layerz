LAPTOP_KEEB=/dev/input/by-path/platform-i8042-serio-0-event-kbd

KEEB=$LAPTOP_KEEB

# zig build && \
#   intercept -g $KEEB | zig-out/bin/layerz | uinput -d $KEEB
zig build -Drelease-safe && \
  sudo intercept -g $KEEB | zig-out/bin/latency

zig build -Drelease-safe && \
  sudo intercept -g $KEEB | zig-out/bin/layerz | zig-out/bin/latency
