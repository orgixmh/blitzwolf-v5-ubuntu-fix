# BlitzWolf V5 Projector Fixer

Linux/Ubuntu fixer for problematic HDMI/DP projectors that expose unstable EDID data and confuse the desktop display layout.

This project was created for a **BlitzWolf V5 projector**, but the fix is not strictly device-specific. It should also work with other projectors/HDMI devices that have the same behavior:

- unstable or wrong EDID identity
- random fallback resolution
- FHD / 1920x1080 native resolution
- display remains logically connected even when the projector is powered off

## The problem

Some BlitzWolf V5 projectors expose inconsistent EDID data over HDMI.

In our case, the same physical projector sometimes appeared as:

```text
STK / S2-TEK TV / SANTAK-like device
Preferred resolution: 1920x1080
```

and other times as:

```text
SYN / Non-PnP
Preferred resolution: 1024x768
```

Because Linux/GNOME identifies monitors based on EDID, Ubuntu treats these as different displays. This causes two main problems.

## Problem 1: Random EDID and wrong resolution

Sometimes the projector boots with the correct EDID and Ubuntu selects the expected native resolution:

```text
1920x1080
```

Other times, the projector exposes a broken/fallback EDID and Ubuntu selects:

```text
1024x768
```

This also causes GNOME to forget the saved monitor layout, because it thinks a different monitor was connected.

### Solution

The installer can apply a Linux DRM/KMS EDID override.

It installs a known-good EDID binary to:

```text
/lib/firmware/edid/blitzwolf-v5-projector.bin
```

and adds a GRUB kernel parameter similar to:

```text
drm.edid_firmware=DP-1:edid/blitzwolf-v5-projector.bin
```

This forces the Linux kernel to use the known-good EDID for the projector connector, instead of trusting the unstable EDID sent by the projector.

After installation, a reboot is required for the EDID override to become active.

## Problem 2: Projector appears connected even when powered off

When the projector is powered off, the HDMI board may still keep the connector logically alive.

Ubuntu still sees the projector as connected, so windows may open on the powered-off projector screen.

Physically, the projector is off. Logically, Linux still sees a connected display.

### Solution

The installer can install a user-level systemd service that monitors DRM hotplug events:

```text
udevadm monitor --kernel --property --subsystem-match=drm
```

When the projector is powered on or off, the GPU emits a hotplug event.

The service watches the short transition pattern reported by `xrandr`.

Power-off pattern:

```text
DP-1 disconnected 1920x1080+0+0 ...
```

Power-on pattern:

```text
DP-1 disconnected (normal left inverted right x axis y axis)
```

Based on this pattern, the service automatically applies the correct layout.

When the projector is powered on:

```text
Projector: enabled at 1920x1080, positioned left
Main monitor: primary, positioned right
```

When the projector is powered off:

```text
Projector: disabled
Main monitor: primary, moved to 0x0
```

This prevents applications from opening on the powered-off projector.

## What the installer does

The installer script is:

```text
blitzwolf-v5-fixer.sh
```

It can install or uninstall two independent fixes:

1. **EDID override**
   - installs the known-good EDID binary
   - configures GRUB
   - updates initramfs
   - updates GRUB
   - requires reboot

2. **Hotplug layout service**
   - installs a user systemd service
   - monitors projector ON/OFF hotplug events
   - automatically enables/disables the projector with `xrandr`
   - does not require reboot

The installer checks the current system state first.

If the service is already installed, it offers to uninstall it.

If the EDID override is already installed and configured, it offers to uninstall it.

## Directory structure

Expected layout:

```text
.
├── blitzwolf-v5-fixer.sh
└── edid-bin/
    └── blitzwolf-v5-projector.bin
```

The EDID binary should be the known-good EDID dump from the projector when it is detected correctly as a 1920x1080 device.

## Requirements

Tested on Ubuntu with GNOME/X11.

Required tools:

```text
xrandr
udevadm
systemctl
python3
flock
```

Recommended:

```text
edid-decode
```

Install the recommended tool with:

```bash
sudo apt install edid-decode
```

## Installation

Make the installer executable:

```bash
chmod +x blitzwolf-v5-fixer.sh
```

Run it:

```bash
./blitzwolf-v5-fixer.sh
```

The installer will explain what the EDID override does before asking for confirmation.

## Checking service status

```bash
systemctl --user status blitzwolf-v5-fixer.service
```

Follow the user service log:

```bash
journalctl --user -u blitzwolf-v5-fixer.service -f
```

Follow the script log:

```bash
tail -f ~/blitzwolf-v5-fixer.log
```

## Checking EDID override status

Check the configured GRUB command line:

```bash
grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub
```

Check if the EDID override is active in the current boot:

```bash
cat /proc/cmdline | grep drm.edid_firmware
```

Check the current connector state:

```bash
xrandr | grep -E '^DP-1|^DP-3'
```

# Notes

It is designed for the specific ON/OFF transition pattern observed on the BlitzWolf V5, but it may work with any projector or HDMI device that behaves similarly.

If another device exposes a different resolution, different connector behavior, or different hotplug transition pattern, the script may need minor adjustments.

## Uninstall

Run the installer again:

```bash
./blitzwolf-v5-fixer.sh
```
