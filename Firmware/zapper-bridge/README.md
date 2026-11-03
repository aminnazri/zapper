# Zapper Bluetooth bridge

An ESP32 board that lets Zapper control a TV over Bluetooth instead of Wi-Fi.
The TV pairs with the board as a Bluetooth keyboard + mouse called
**Zapper Remote**; Zapper drives the board over USB.

macOS doesn't let apps act as a Bluetooth keyboard or mouse, which is why a
board is needed at all.

## What you get

- Works with no shared Wi-Fi.
- A real mouse pointer on the TV (browsers, any app).
- Real typing in every app, including digits and symbols.
- D-pad, Back, Home, volume, mute, media keys, power (if the TV wakes on Bluetooth).

Not over Bluetooth: casting, opening apps by link, HDMI input keys, and the
TV's volume level/app name (the TV doesn't report those to a keyboard).

## Board

Any ESP32 with Bluetooth LE: **ESP32 DevKit (ESP32-WROOM-32)**, **ESP32-S3**,
or **ESP32-C3**. Not the ESP32-S2 (no Bluetooth). Use a USB *data* cable.

## Set up

1. Plug the board into the Mac.
2. Run `Scripts/flash-bridge.sh`. First run installs PlatformIO into
   `~/.zapper-pio` and downloads the toolchain (a few minutes).
   If it can't identify the chip: hold **BOOT**, tap **RESET/EN**, release
   **BOOT**, and run it again.
3. On the TV: **Settings › Remotes & Accessories › Pair accessory** and choose
   **Zapper Remote**. (Only once; the TV reconnects by itself afterwards.)
4. In Zapper, pick **Bluetooth adapter** in the TV list. The header says
   "Bluetooth · TV connected" when the TV is paired.

The board can stay plugged in. One board serves one TV at a time; to move it
to another TV, pair it there (forget it on the old TV first).

## Protocol

One line per command at 115200 baud — see the top of `src/main.cpp`.
