# DockDDC

A tiny macOS menu bar app that switches your monitor's input to your Mac when you plug into a USB-C dock, even when the dock blocks normal DDC/CI.

## The problem

You share one monitor between a Mac (USB-C dock, DisplayPort out) and another device on HDMI. You plug the Mac in and the monitor stays on HDMI. "Detect Displays" does nothing. The only fix is to unplug the HDMI cable so the monitor rescans its inputs.

Tools like m1ddc, Lunar or BetterDisplay can normally send the monitor an input-switch command over DDC/CI. Many docks route DisplayPort through an MST hub that drops those commands, so they fail with an I/O error.

## How it works

1. **Relay through the hub.** The hub still forwards I2C when the request is wrapped as a DisplayPort sideband `REMOTE_I2C_WRITE` message addressed to the hub's downstream port. DockDDC builds that message and writes it to the hub's DPCD mailbox, with the DDC/CI "set input source" command (VCP `0x60`) inside it.
2. **Catch the window.** After plug-in, the hub appears on the Mac for a moment before a monitor parked on another input powers its DP input down. DockDDC listens for the hub to register and sends the input switch right away. It does the same on wake.

It only talks to external DisplayPort devices that advertise MST capability, so plain monitors and projectors are never touched.

## Requirements

- Apple Silicon Mac, macOS 14 or later
- A USB-C dock whose DisplayPort output goes through an MST hub
- A monitor that supports DDC/CI input switching

## Build and run

```
./build.sh
open DockDDC.app
```

To start at login, add `DockDDC.app` in System Settings, General, Login Items.

## Menu

- **Switch Monitor to This Mac** sends the primary input code.
- **Switch Monitor to Other Input** sends the secondary input code.
- **Reset External Resolution** sets external displays to their native resolution.
- **Auto-switch on Connect** turns the plug-in and wake behavior on or off.

## Configuration

Defaults suit a monitor on hub port 2, with DisplayPort 1 as the Mac input and HDMI 1 as the other input.

```
defaults write io.github.dockddc hubPort -int 2          # hub downstream port the monitor is on
defaults write io.github.dockddc inputPrimary -int 15    # 15 DP1, 16 DP2, 17 HDMI1, 18 HDMI2, 27 USB-C
defaults write io.github.dockddc inputSecondary -int 17
```

Restart the app after changing these. To find your hub port, try `0` to `3` and see which one makes the monitor respond.

## Limitations

- Writes are blind. The Mac's display coprocessor consumes the hub's replies, so the app cannot read the monitor's current input.
- If the monitor has already powered down its DP input before the app sees the hub, nothing on the Mac can reach it. Replug once.
- This uses private IOKit functions. If a future macOS removes them, the switching items are disabled instead of crashing.

## License

MIT
