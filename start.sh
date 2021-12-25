LAPTOP_KEEB=platform-i8042-serio-0-event-kbd

set -e

KEEB=/dev/input/by-path/${1:-$LAPTOP_KEEB}

if [[ ! -e $(realpath $KEEB) ]]; then
  echo "Unknown keyboard id: $KEEB"
  echo "Chose from:"
  ls /dev/input/by-path
  exit 1
fi

# Use `zig build` to build in debug mode and have detailed logs about input/output
# zig build -Drelease-safe
# zig build

sudo intercept -g $KEEB | zig-out/bin/layerz | sudo uinput -d $KEEB
