# DockDDC

Control your external monitor from the macOS menu bar, even through a USB-C dock that blocks monitor commands. Switch inputs, change brightness, contrast and volume, and have the monitor jump to your Mac the moment you dock.

## Why this exists

One monitor, two devices. The Mac goes into a USB-C dock over DisplayPort, and a PS5 sits on HDMI. Every time the Mac docked, the monitor stayed on the PS5. "Detect Displays" did nothing. The only fix was to pull the PS5's HDMI cable and plug it back in.

The usual answer is DDC/CI, the channel a computer uses to send commands to a monitor, such as "switch to DisplayPort". Tools like m1ddc, MonitorControl and BetterDisplay all use it. Through this dock, every one of them failed with an I/O error.

## Is this a Mac-only problem?

Partly.

- **The monitor half happens everywhere.** With Auto Select on, most monitors only rescan inputs when the current one loses signal. A PS5 or PC on HDMI keeps that signal alive, so a newly connected laptop gets ignored on any OS.
- **The dock half is macOS.** Most USB-C docks route DisplayPort through an MST (Multi-Stream Transport) hub. Apple Silicon Macs don't support MST, and macOS can't route DDC through these hubs. On Windows, GPU drivers do support MST, so tools like ControlMyMonitor or Monitorian can usually switch inputs through the same dock.

DockDDC fixes the macOS half by talking to the hub directly.

## Features

- **Auto-switch on connect.** When the dock's hub appears, or the Mac wakes, the monitor is told to switch to the Mac's input.
- **Switch Monitor to This Mac** in one click.
- **Input Source menu** for DisplayPort 1 and 2, HDMI 1 and 2, and USB-C. You can flip to your console without touching the monitor.
- **Brightness, Contrast and Volume sliders** that change the monitor's hardware settings, not a software dimming overlay.
- **Day, Evening and Night presets** for brightness and contrast.
- **Reset External Resolution** to recover from a display stuck in a low-resolution mode.

## How it works

### 1. The route

```
Mac (DCP display engine)
  └── USB-C, DisplayPort Alt Mode
        └── Dock: MST hub  (DPCD branch device)
              ├── port 0
              ├── port 1
              ├── port 2 ── DisplayPort ── Monitor
              └── port 3
```

macOS sends DDC as I2C over the DisplayPort AUX channel. An MST hub only forwards I2C to a downstream monitor when the request is addressed to a specific downstream port. A plain I2C-over-AUX write reaches the hub itself and gets dropped.

### 2. The relay

DisplayPort 1.2 defines sideband messages for talking through MST hubs. One of them, `REMOTE_I2C_WRITE`, tells the hub "write these bytes to I2C address X on downstream port N". DockDDC builds that message by hand and writes it into the hub's sideband mailbox at DPCD address `0x1000`:

```
header   10 LL CC          LCT=1 (hub itself), body length, CRC-4
body     23                REMOTE_I2C_WRITE
         P0                downstream port P in the high nibble
         37                I2C address 0x37 (DDC/CI)
         07                number of bytes
         51 84 03 VV HH LL CS   DDC/CI "set VCP feature" packet
         CRC-8
```

`VV` is the feature code: `0x60` for input source, `0x10` for brightness, `0x12` for contrast and `0x62` for volume. After writing, the app acknowledges the hub's reply interrupt so the mailbox is free for the next message.

The DPCD access goes through the `IODPDevice` functions in IOKit. They are private, so the app looks them up at runtime and disables the relay items if they are missing.

### 3. The timing window

When the Mac docks, the hub registers on the Mac almost at once. A monitor parked on HDMI turns off its DisplayPort input shortly after, and from then on the Mac can't reach it. DockDDC subscribes to IOKit notifications for the external DisplayPort device and sends the input switch as soon as it appears, then again 1.5 seconds later in case the first is lost.

### 4. Safety

The app only sends sideband messages to external DisplayPort devices that advertise MST support in DPCD register `0x021`. A projector or plain monitor plugged in directly never receives them. It makes no network calls, needs no admin rights and stores only its settings.

## Requirements

- Apple Silicon Mac on macOS 14 or later
- A USB-C dock whose DisplayPort output goes through an MST hub, which is most non-Thunderbolt docks
- A monitor with DDC/CI turned on in its on-screen menu

## Build and run

```
git clone https://github.com/sanjeevmax6/dockddc.git
cd dockddc
./build.sh
open DockDDC.app
```

The build needs only the Xcode Command Line Tools (`xcode-select --install`). To start at login, add `DockDDC.app` in System Settings, General, Login Items.

## Configuration

The defaults assume the monitor is on hub port 2 and the Mac is on DisplayPort 1.

```
defaults write io.github.dockddc hubPort -int 2
defaults write io.github.dockddc inputPrimary -int 15
```

Input codes are `15` for DisplayPort 1, `16` for DisplayPort 2, `17` for HDMI 1, `18` for HDMI 2 and `27` for USB-C. Some monitors use other values. Restart the app after changing settings.

### Finding your hub port

Drag the Brightness slider. If the monitor doesn't respond, try the next port and drag again:

```
defaults write io.github.dockddc hubPort -int 0   # then 1, 2, 3
```

## Troubleshooting

- **"No MST dock link found".** The Mac can't see the dock's hub. Replug the USB-C cable. If the monitor has already turned its DisplayPort input off, replug the other device's HDMI cable once.
- **Nothing happens.** Check that DDC/CI is enabled in the monitor's menu, and find the right hub port as described above.
- **The sliders don't match the monitor.** Replies from the hub are consumed by macOS, so the app can't read the monitor's current values. The sliders show the last value you set.
- **The Mac takes the monitor back after waking.** Turn off Auto-switch on Connect.

## Limitations

- Writes are blind, so the app cannot read the current input or brightness.
- Only one monitor behind the hub is supported.
- Thunderbolt docks that pass DisplayPort through without an MST hub don't need this. m1ddc or BetterDisplay already work on them.

## References

- VESA DisplayPort 1.2, sideband messaging and `REMOTE_I2C_WRITE`
- VESA MCCS, the Monitor Control Command Set, for VCP codes
- [m1ddc](https://github.com/waydabber/m1ddc) and [MonitorControl](https://github.com/MonitorControl/MonitorControl), for DDC on Apple Silicon
- [MonitorControl issue 1403](https://github.com/monitorcontrol/monitorcontrol/issues/1403), about DDC through MST docks on Mac

## License

MIT
