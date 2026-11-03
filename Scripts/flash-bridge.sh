#!/bin/bash
# Installs the Zapper Bluetooth bridge firmware on an ESP32 plugged in by USB.
#
#   Scripts/flash-bridge.sh            find the board and flash it
#   Scripts/flash-bridge.sh /dev/cu.X  use this serial port
#
# The first run installs PlatformIO into ~/.zapper-pio (a private Python
# environment) and downloads the ESP32 toolchain, which takes a few minutes.
# Quit Zapper first: only one program can hold the board's serial port.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="$ROOT/Firmware/zapper-bridge"
VENV="$HOME/.zapper-pio"
PIO="$VENV/bin/pio"

if [ ! -x "$PIO" ]; then
    echo "Installing PlatformIO into $VENV…"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q platformio
fi

PORT="${1:-}"
if [ -z "$PORT" ]; then
    # USB serial adapters on ESP32 boards: CP210x, CH34x, FTDI, native USB.
    PORT="$(ls /dev/cu.usbserial* /dev/cu.usbmodem* /dev/cu.SLAB_USBtoUART* \
                /dev/cu.wchusbserial* 2>/dev/null | head -1 || true)"
fi
if [ -z "$PORT" ]; then
    echo "No ESP32 found. Plug it in with a USB *data* cable (charge-only cables"
    echo "don't work). Boards with a CH340 chip may need its driver on older macOS."
    exit 1
fi
echo "Board on $PORT"

if pgrep -x Zapper >/dev/null; then
    echo "Quitting Zapper so the port is free…"
    pkill -x Zapper || true
    sleep 1
fi

# Ask the chip what it is, to pick the matching build.
"$PIO" pkg install -g -t "platformio/tool-esptoolpy" >/dev/null 2>&1 || true
ESPTOOL="$(ls -d "$HOME"/.platformio/packages/tool-esptoolpy*/esptool.py 2>/dev/null | head -1)"
CHIP="$("$VENV/bin/python" "$ESPTOOL" --port "$PORT" chip_id 2>/dev/null | grep -m1 'Chip is' || true)"
case "$CHIP" in
    *ESP32-S3*) ENV=esp32-s3 ;;
    *ESP32-C3*) ENV=esp32-c3 ;;
    *ESP32-S2*) echo "This is an ESP32-S2, which has no Bluetooth. Use an ESP32, S3 or C3."; exit 1 ;;
    *ESP32*)    ENV=esp32dev ;;
    *)
        echo "Couldn't identify the chip on $PORT ($CHIP)."
        echo "Hold the board's BOOT button, tap RESET (EN), release BOOT, and run this again."
        exit 1 ;;
esac
echo "${CHIP#*Chip is } → building '$ENV'"

cd "$FW"
"$PIO" run -e "$ENV" -t upload --upload-port "$PORT"

echo
echo "Done. On the TV: Settings › Remotes & Accessories › Pair accessory,"
echo "then pick \"Zapper Remote\". Then open Zapper and choose Bluetooth adapter."
