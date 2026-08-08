# gnome-monitor-toggle

Briefly turn a single monitor off and back on under GNOME — a workaround for
amdgpu display freezes (`flip_done timed out`).

The change is temporary: nothing is written to your saved monitor
configuration, and the previous layout is restored exactly, even if you
abort with `Ctrl+C`.

## The problem this solves

The amdgpu driver sometimes wedges the display pipeline. The picture freezes
while the machine keeps running — SSH still works, audio keeps playing, the
GPU keeps computing. The journal shows:

```
amdgpu 0000:c4:00.0: [drm] *ERROR* [CRTC:428:crtc-1] flip_done timed out
```

Crucially there is **no GPU reset and no ring timeout**. Only the display
controller is stuck. Disabling the affected output and re-enabling it forces
a fresh modeset, which rebuilds the pipeline and clears the freeze.

Check whether you have this particular problem:

```bash
journalctl -b -1 -k | grep -E "flip_done|GPU reset|ring .*timeout"
```

If you see `flip_done` **without** an accompanying GPU reset, this script may
help you.

This is a workaround, not a fix. You run it *after* a freeze; it does not
prevent one.

## Requirements

- A GNOME session (mutter) — Wayland or X11
- `python3` with PyGObject

```bash
# Fedora
sudo dnf install python3-gobject
# Debian/Ubuntu
sudo apt install python3-gi
# Arch
sudo pacman -S python-gobject
```

## Usage

```bash
./monitor-toggle.sh --list                # show available monitors
./monitor-toggle.sh "Odyssey G70D"        # toggle by model name (recommended)
./monitor-toggle.sh DP-7                  # toggle by connector name
./monitor-toggle.sh HDMI-1 10             # keep it off for 10 seconds
```

Default off-time is 5 seconds.

> **Do not go below ~3 seconds.** Monitors that enter standby on signal loss
> may refuse a signal that returns too quickly and simply stay dark. Then
> only switching the input source or power-cycling the monitor brings it
> back. This is easy to trigger accidentally while testing.

## Finding monitor names

```bash
./monitor-toggle.sh --list
```

```
Available monitors:
  DP-6         active    (SAM SAMSUNG)
  DP-7         active    (SAM Odyssey G70D)
  eDP-1        inactive  (TMA TL134ADXP03)
```

`gdctl show` gives more detail (vendor, product, serial, modes).

**`xrandr` is not suitable for this.** Under Wayland it only runs through
XWayland, reports just the currently *active* outputs, and gives no model
names — inactive outputs such as `eDP-1` with the lid closed are missing
entirely. `xrandr --listmonitors` will mislead you here.

## Prefer model names over DP numbers

DP connector numbers are **not stable**. They shift when cables are replugged
or depending on enumeration order.

This matters more than it sounds. A shortcut here pointed at `DP-4` for a
long time; after a renumbering the outputs were called `DP-6`/`DP-7`. The
script aborted with `monitor 'DP-4' not found` — but during a freeze nobody
reads stderr. The workaround appeared to do nothing, which made the freeze
look like it had a brand-new cause. It cost hours of chasing the wrong lead.

So `<MONITOR>` also accepts the model or vendor name as a case-insensitive
substring. That survives replugging. Ambiguous matches are rejected rather
than guessed:

```
Error: 'SAM' matches several monitors: DP-6, DP-7
```

## Binding it to a keyboard shortcut

The point is to trigger this *while the screen is frozen*, so a shortcut is
essential.

**GNOME Settings → Keyboard → Custom Shortcuts:**

```
Name:    Toggle Monitor
Command: /path/to/monitor-toggle.sh "Odyssey G70D"
Key:     Shift+Ctrl+Alt+M
```

**From a phone via [GSConnect](https://github.com/GSConnect/gnome-shell-extension-gsconnect):**
add the same command under the device's *Run Commands*. Useful when the
frozen display makes the keyboard shortcut hard to confirm. GSConnect runs
commands through `/bin/sh -c`, so quoting and `~` work as expected.

If you use both, remember the command exists in **two** places — update both
when a monitor changes.

## Limitations

- Only works under GNOME/mutter. Other compositors have no equivalent of
  `org.gnome.Mutter.DisplayConfig`.
- Cannot disable your only active monitor — mutter requires at least one
  output to remain. The script refuses with a clear message instead of
  producing an invalid configuration.
- Does not address the underlying amdgpu bug.

## License

MIT — see [LICENSE](LICENSE).
