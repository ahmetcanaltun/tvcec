# tvcec

Turns a TV off and on over HDMI-CEC when a Mac's screens or the Mac itself sleep and wake. It also makes CEC transmit work on the built-in HDMI port of a MacBook Pro where macOS leaves it disabled.

**Tested on one setup only:** MacBookPro18,3 (M1 Pro), macOS 27, Samsung LE22D450G1W. Other Macs and TVs are untested. Reports are welcome.

## Risks

This tool uses undocumented interfaces that Apple does not support, and a macOS update can break it. On the M1 Pro it writes to an SMC GPIO pin (`gP12`) as root. That write is the part to weigh before installing:

- `gP12` serves other purposes on other Macs. tvcec writes it only if this Mac's device tree names it `function-hdmi_cec_en`; otherwise it leaves the pin alone.
- The pin goes high only while a command runs.
- SIP stays on and no system files are changed. tvcec adds a sudoers rule for `tvcec wake` and `tvcec standby`.

Use it at your own risk.

## How it works

- **CEC:** DPCD CEC tunneling registers (`0x3000` block), reached through the undocumented `IODPDevice*` functions, as in [MacTV](https://github.com/pengchujin/MacTV). Writes outside the CEC block are refused, so display settings are not touched.
- **Enable pin:** macOS does not enable CEC on this port, and the TV does not acknowledge frames until `gP12` is high.
- **Screen sleep:** the TV goes to standby 30 seconds after the screens sleep, unless they wake first.
- **System sleep, logout and shutdown:** the TV goes to standby right away.
- **Wake:** the TV turns on and is asked for its power status. The command is retried if it keeps reporting standby.

## Install

You need Xcode Command Line Tools and CEC enabled on the TV (Samsung calls it Anynet+).

```sh
./build.sh
build/tvcec selftest
./install.sh              # /usr/local/bin/tvcec, /etc/sudoers.d/tvcec, LaunchAgent
./uninstall.sh            # add --purge-logs to delete the logs too
```

The self test does not touch hardware, and its `info` line shows whether the device tree maps the pin on your Mac.

## Commands

```sh
sudo tvcec wake       # turn the TV on
sudo tvcec standby    # put the TV in standby
sudo tvcec status     # port, address and TV response
tvcec monitor 30      # listen to CEC traffic
tvcec selftest        # logic tests without hardware
```

## Test

```sh
tail -f ~/Library/Logs/tvcec/tvcec.log
pmset displaysleepnow     # in another window
```

The TV should turn off after about 30 seconds and turn on when you move the mouse.

## Troubleshooting

| Symptom | Check |
|---|---|
| The TV stays on | Look for `system will sleep` or `screens slept` in the log. An app can keep the screen awake. |
| `did not acknowledge` | Check that CEC is on, run `sudo tvcec status` and replug the cable. |
| `device tree does not map gP12` | This Mac uses a different design. tvcec sends CEC without the pin, which may not reach the TV. |
| `gP12 write failed` | Run with `sudo`. For the agent, check `sudo visudo -cf /etc/sudoers.d/tvcec`. |
| `no CEC-capable port` | Check the HDMI cable. A macOS update may also have changed `IODPDevice`. |
| Video drops out | Run `./uninstall.sh` and restart the Mac. |
| Another app also controls the TV | Turn off that app's CEC control. |
