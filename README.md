# gnome-monitor-toggle

Briefly turn a single monitor off and back on under GNOME — a workaround for
amdgpu display freezes (`flip_done timed out`).

The change is temporary: nothing is written to your saved monitor
configuration, and the previous layout is restored exactly, even if you abort
with `Ctrl+C`.

---

## Why this script exists

If you landed here searching for *"AMD screen freeze but system still
running"*, *"amdgpu flip_done timed out"*, *"GNOME display freeze Wayland
AMD"*, *"Strix Halo freeze"* or *"ROG Flow Z13 freeze Linux"* — this is
probably the failure you are hitting.

The symptom is distinctive and easy to misdiagnose:

- The **picture freezes completely**. Often mid-frame, sometimes with the
  cursor still moving, sometimes not.
- **The machine is not dead.** Audio keeps playing. SSH from another device
  works. Long-running jobs keep running. Disk activity continues.
- **Switching VTs does nothing.** `Ctrl+Alt+F3` gives you nothing or another
  frozen screen.
- Eventually the GNOME session may die and drop you at the login screen — or
  you power-cycle the machine because nothing else responds.

What is actually happening: the amdgpu driver has wedged its **display
pipeline**. The GPU itself is fine. It keeps executing work, the compositor
keeps rendering — the frames just never reach the screen because the atomic
page flip never completes. The kernel says so:

```
amdgpu 0000:c4:00.0: [drm] *ERROR* [CRTC:428:crtc-1] flip_done timed out
```

Because everything *else* keeps working, this gets misread as a compositor
crash, a GPU hang, a RAM problem, or an overheating issue. It is none of
those. There is **no GPU reset and no ring timeout** in the log — that
combination is the fingerprint.

**Forcing a modeset on the affected output rebuilds the pipeline and clears
the freeze.** Disabling a monitor and re-enabling it does exactly that, which
is all this script does — via the same D-Bus interface that GNOME Settings
uses, so it works under Wayland where `xrandr` cannot help you.

This is a workaround, not a fix. You run it *after* a freeze; it does not
prevent one. The underlying driver bug is unresolved.

---

## Is this your problem?

Run this after a freeze (`-b -1` reads the previous boot, i.e. before the
reboot you just did):

```bash
journalctl -b -1 -k | grep -E "flip_done|GPU reset|ring .*timeout"
```

| What you see | Verdict |
|---|---|
| `flip_done timed out`, **no** GPU reset, **no** ring timeout | This script may help you |
| `GPU reset begin` / `ring ... timeout` | Different problem — an actual GPU hang |
| Nothing at all | Not this failure mode |

A useful detail when reading the log: the **first** `[CRTC:n]  flip_done`
line marks the moment the freeze began. Later bare `flip_done` lines are
usually just the session tearing down afterwards.

---

## Affected hardware

**Confirmed** — the system this was developed and reproduced on:

| | |
|---|---|
| Machine | ASUS ROG Flow Z13 (GZ302EAC), BIOS GZ302EAC.301 (2025-10-27) |
| CPU/APU | AMD Ryzen AI MAX+ 395 w/ Radeon 8060S (**Strix Halo**, `1002:1586`) |
| Distro | Fedora Linux 44 (Workstation) |
| Kernel | 7.1.5, 7.1.6 and 7.1.7 — **all affected**, so not a single-version regression |
| Desktop | GNOME Shell 50.4 / mutter 50.4, Wayland |
| Mesa | 26.1.6 |
| Displays | Two external 4K@120 over DisplayPort, internal panel disabled |

**Plausibly affected, but unverified.** The code path that fails
(`amdgpu_dm_commit_planes` in amdgpu's Display Core) is not specific to Strix
Halo — it is shared by essentially every AMD GPU and APU that uses DC/DCN.
That covers, among others:

- **APUs:** Strix Halo (Ryzen AI Max 300), Strix Point (Ryzen AI 300),
  Hawk Point / Phoenix (Ryzen 7040/8040), Rembrandt (Ryzen 6000)
- **Discrete:** Radeon RX 6000 / 7000 / 9000 series

To be explicit: *sharing a code path is not evidence of the same bug.* Nobody
has confirmed these are affected. That is precisely why reports are
wanted — see [Report your hardware](#report-your-hardware) below.

If your setup involves external DisplayPort monitors (dock, USB-C/DP-Alt,
lid closed with the internal panel off), you are in the configuration where
this was observed.

---

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

## Install

```bash
git clone https://github.com/luff-biz/gnome-monitor-toggle.git
cd gnome-monitor-toggle
chmod +x monitor-toggle.sh
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
> may refuse a signal that returns too quickly and simply stay dark. Then only
> switching the input source or power-cycling the monitor brings it back. This
> is easy to trigger accidentally while testing — it happened during
> development of this script.

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

---

## Triggering it during a freeze

A frozen screen is a bad time to open a terminal. Set up a trigger **before**
you need it. Two approaches, and they complement each other — set up both.

### 1. Keyboard shortcut

Works as long as the input stack is alive, which it usually is.

**GNOME Settings → Keyboard → View and Customize Shortcuts → Custom
Shortcuts → `+`**

| Field | Value |
|---|---|
| Name | `Toggle Monitor` |
| Command | `/path/to/monitor-toggle.sh "Odyssey G70D"` |
| Shortcut | `Shift+Ctrl+Alt+M` |

Use an unusual modifier combination — you do not want to fire this by
accident. Add one entry per display you want to be able to kick.

The equivalent from the command line, if you prefer scripting it:

```bash
BASE=org.gnome.settings-daemon.plugins.media-keys
PATH0=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/

gsettings set $BASE custom-keybindings "['$PATH0']"
gsettings set $BASE.custom-keybinding:$PATH0 name    'Toggle Monitor'
gsettings set $BASE.custom-keybinding:$PATH0 command '/path/to/monitor-toggle.sh "Odyssey G70D"'
gsettings set $BASE.custom-keybinding:$PATH0 binding '<Shift><Control><Alt>m'
```

### 2. From your phone, via GSConnect

The fallback for when the keyboard shortcut does not land — and it is
genuinely reassuring to have a trigger that does not depend on the frozen
machine's input handling at all.

[GSConnect](https://github.com/GSConnect/gnome-shell-extension-gsconnect) is
a GNOME Shell extension that pairs your phone with your desktop (it speaks
the KDE Connect protocol).

1. Install the **GSConnect** extension on the desktop and the **KDE Connect**
   app on your phone.
2. Pair the two devices — same network, confirm the request on both ends.
3. Open GSConnect preferences → select your device → enable the
   **Run Commands** plugin → open its settings.
4. Add a command:

   | Field | Value |
   |---|---|
   | Name | `Toggle Monitor` |
   | Command | `/path/to/monitor-toggle.sh "Odyssey G70D"` |

5. On the phone: open the device in KDE Connect → **Run Command** → tap it.

Use an **absolute path**. GSConnect executes commands through `/bin/sh -c`,
so quoting and `~` do work — but an absolute path removes any doubt about the
working directory.

> **If you set up both, the command now exists in two places.** When a monitor
> changes, update the keyboard shortcut *and* the GSConnect entry. Forgetting
> one is exactly how you end up with a workaround that silently does nothing.

---

## Prefer model names over DP numbers

DP connector numbers are **not stable**. They shift when cables are replugged
or depending on enumeration order.

This matters more than it sounds. A shortcut here pointed at `DP-4` for a long
time; after a renumbering the outputs were called `DP-6`/`DP-7`. The script
aborted with `monitor 'DP-4' not found` — but during a freeze nobody reads
stderr. The workaround appeared to do nothing, which made the freeze look like
it had a brand-new cause, and sent the investigation down the wrong path for
hours.

So `<MONITOR>` also accepts the model or vendor name as a case-insensitive
substring. That survives replugging. Ambiguous matches are rejected rather
than guessed:

```
Error: 'SAM' matches several monitors: DP-6, DP-7
```

If a toggle ever seems to do nothing, run `--list` first and check that the
names in your shortcuts still exist.

---

## Report your hardware

**The most useful thing you can contribute is a data point.** It is currently
unknown how far this bug reaches — which APU generations, which kernels,
whether a dock or specific monitor is required to trigger it.

If you hit `flip_done timed out` without a GPU reset, please
[open an issue](https://github.com/luff-biz/gnome-monitor-toggle/issues/new)
and include the output of this — run it from the repo directory:

```bash
{
  echo "### System"
  . /etc/os-release && echo "Distro:  $NAME $VERSION"
  echo "Kernel:  $(uname -r)"
  echo "CPU:     $(lscpu | sed -n 's/^Model name: *//p' | sed 's/^ *//')"
  echo "GPU:     $(lspci -nn | grep -iE 'VGA|Display|3D' | cut -d' ' -f2-)"
  echo "Machine: $(cat /sys/class/dmi/id/sys_vendor) $(cat /sys/class/dmi/id/product_name)"
  echo "BIOS:    $(cat /sys/class/dmi/id/bios_version) $(cat /sys/class/dmi/id/bios_date)"
  echo "Session: ${XDG_SESSION_TYPE:-unknown} / $(gnome-shell --version)"
  echo
  echo "### Monitors"
  ./monitor-toggle.sh --list
  echo
  echo "### Freeze signature (previous boot)"
  journalctl -b -1 -k 2>/dev/null | grep -E "flip_done|GPU reset|ring .*timeout" | tail -10
}
```

It prints nothing secret — machine model, kernel, GPU, monitor models and the
matching log lines. Read it before pasting if you would rather check.

Also worth mentioning in your report:

- **Did the toggle actually clear the freeze?** Negative results are just as
  valuable.
- Does it only happen with **external displays**, a **dock**, or after
  **suspend/resume**?
- Roughly how often, and does anything reliably trigger it?

---

## Limitations

- Only works under GNOME/mutter. Other compositors have no equivalent of
  `org.gnome.Mutter.DisplayConfig`.
- Cannot disable your only active monitor — mutter requires at least one
  output to remain. The script refuses with a clear message instead of
  producing an invalid configuration.
- Does not address the underlying amdgpu bug.

## License

MIT — see [LICENSE](LICENSE).
