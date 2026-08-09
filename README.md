# gnome-monitor-toggle

Briefly turn a single monitor off and back on under GNOME — a workaround for
display freezes on AMD systems (`flip_done timed out`).

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

What is actually happening: the **display pipeline is wedged**. The GPU itself
is fine. It keeps executing work, the compositor keeps rendering — the frames
just never reach the screen because the atomic page flip never completes. The
kernel says so:

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
prevent one.

---

## What causes it is an open question

**Please read this before concluding you have "the amdgpu bug".** The failure
*surfaces* in amdgpu's display code, but that does not mean the driver is the
root cause, and the setup it was observed on has several other suspects.

On the reference system the two external monitors do **not** hang off a plain
DisplayPort cable. They run through a **Thunderbolt 5 dock**, which means:

- **DisplayPort tunnelled over USB4**, negotiated at **40 Gb/s**
  (`2 lanes * 20 Gb/s` — the host is USB4, so 40 Gb/s is the ceiling here
  regardless of the dock being TB5)
- **MST** (Multi-Stream Transport) — both displays share one link
- **DSC** (Display Stream Compression), confirmed by
  `MST_DSC dsc precompute` in the kernel log

And the bandwidth is genuinely tight. Two 4K@120 streams at 8 bpc need roughly
24 Gb/s of payload each — about 48 Gb/s combined, on a 40 Gb/s tunnel that
also carries USB and PCIe traffic. It only fits *because* of DSC.
**DSC over MST over USB4 tunnelling is one of the most fragile combinations in
the whole display stack.**

There is also a timing correlation. `HPD RX IRQ` is a *sink-initiated*
interrupt — the monitor or hub reporting a link status change or a failed link
training. It clusters tightly around the freezes:

| flip_done timeout | HPD RX IRQ |
|---|---|
| 11:36:57 | 11:36:57 — same second |
| 19:03:31 | 19:03:36 |
| 09:50:23 | 09:50:26 |

**The direction of causation cannot be determined from the log.** The link
events might be triggering the stall — or they might be the driver rebuilding
the link afterwards. Both readings fit the data.

One more hint in the same direction: DP connector numbers on this system
shifted from `DP-4`/`DP-5` to `DP-6`/`DP-7` at some point. With MST, connectors
are **created dynamically** when a topology appears, so a re-enumerated dock
hands out fresh indices. That renumbering was not random driver behaviour — it
was the dock.

### So: driver, dock, or the combination?

| Hypothesis | Supporting | Against |
|---|---|---|
| amdgpu driver bug | Fails inside `amdgpu_dm_commit_planes`; reproduces across ~19 kernel versions | A driver that mishandles a marginal link is not the same as one that wedges on its own |
| Dock / MST / DSC / USB4 | Bandwidth at the limit; sink-initiated HPD events correlate; MST explains the renumbering | Never tested without the dock |
| Interaction of both | Explains why it survives every kernel update | Untested |

**Nobody has run this machine without the dock for long enough to tell.** If
you hit the same freeze on a **directly connected** monitor, that is a
particularly valuable report — it would separate these hypotheses.

### How to narrow it down on your own machine

Roughly in order of usefulness — each isolates one variable:

1. **Remove the dock.** Connect one monitor straight to the machine. If the
   freezes stop over several days, the dock/MST/tunnelling path is implicated.
2. **Drive one display instead of two.** Halves the bandwidth, keeps MST.
3. **Drop to 60 Hz.** Cuts bandwidth demand sharply. If it goes quiet, this is
   a bandwidth/DSC problem rather than a driver logic problem.
4. **Update the dock firmware.**

Please report what you find, positive or negative — see
[Report your hardware](#report-your-hardware).

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

## The reference system

The one machine this has been reproduced on, in full — including the parts
that may well be the actual cause:

| | |
|---|---|
| Machine | ASUS ROG Flow Z13 (GZ302EAC), BIOS GZ302EAC.301 (2025-10-27) |
| CPU/APU | AMD Ryzen AI MAX+ 395 w/ Radeon 8060S (**Strix Halo**, `1002:1586`) |
| Distro | Fedora Linux 43, then 44 (Workstation) |
| Desktop | GNOME Shell / mutter 50.4, Wayland |
| Mesa | 26.1.6 |
| **Dock** | **Razer Thunderbolt 5 Dock**, link negotiated at **40 Gb/s** (USB4) |
| Displays | 2 × 4K@120 over **DP tunnelled through the dock**, via **MST** with **DSC** |
| Internal panel | Disabled (`eDP-1` inactive) |

### Kernel versions

The freeze survives every kernel update. It is documented on **32 separate
days** between 2026-05-03 and 2026-08-09 — that is the full extent of the
journal retention, not the full extent of the problem.

**Confirmed affected** (freeze present in the log while running these):

```
6.19.14-300.fc44
7.0.4    7.0.7    7.0.8    7.0.9    7.0.10    7.0.12    7.0.13
7.1.4    7.1.5    7.1.6    7.1.7
```

**Also run, but before journal retention began** — reported by the user as
already affected, not machine-verifiable:

```
6.17.1-300.fc43
6.19.9   6.19.10   6.19.11   6.19.13   (all .fc43)
```

So: **every kernel series from 6.17 through 7.1**, across a Fedora 43 → 44
upgrade, spanning roughly April to August 2026. Whatever this is, it is not a
regression in one kernel version, and no update has fixed it.

## Might this affect other hardware?

Unknown, and deliberately not overstated.

The code path that fails (`amdgpu_dm_commit_planes`, in amdgpu's Display Core)
is not specific to Strix Halo — it is shared by essentially every AMD GPU and
APU using DC/DCN, including Strix Point, Hawk Point / Phoenix, Rembrandt and
the discrete RX 6000/7000/9000 series.

**But sharing a code path is not evidence of the same bug.** And since the
reference system reaches its displays through a dock, over MST, with DSC, on a
bandwidth-saturated USB4 tunnel, it is entirely possible that the hardware
generation is not the relevant variable at all.

The most informative reports would be:

- Same freeze **without** a dock, on a directly attached monitor
- Same freeze on a **different GPU generation**
- Same freeze with **plenty of bandwidth headroom** (single display, 60 Hz)

See [Report your hardware](#report-your-hardware).

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
unknown how far this reaches — which GPU generations, which kernels, and above
all **whether a dock, MST or DSC is required to trigger it at all**. With one
affected machine there is no way to separate driver from topology.

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
  echo "### Monitors and modes"
  ./monitor-toggle.sh --list
  gdctl show 2>/dev/null | grep -E "Monitor |[0-9]+x[0-9]+@" | sed 's/^ *//'
  echo
  echo "### Dock / link (empty means no Thunderbolt/USB4 dock)"
  command -v boltctl >/dev/null \
    && boltctl list 2>/dev/null | grep -E "^ \*|generation:|rx speed:|tx speed:" \
    || echo "  boltctl not installed"
  echo
  echo "### MST / DSC / link events"
  journalctl -b 0 -k 2>/dev/null \
    | grep -iE "MST_DSC|dsc precompute|link training|dp_mst|HPD RX IRQ" | tail -5
  echo
  echo "### Freeze signature (previous boot)"
  journalctl -b -1 -k 2>/dev/null \
    | grep -E "flip_done|GPU reset|ring .*timeout" | tail -10
}
```

It prints nothing secret — machine model, kernel, GPU, monitor models, dock
model and the matching log lines. Read it before pasting if you would rather
check.

Also worth mentioning in your report:

- **Is a dock involved, or is the monitor connected directly?** This is the
  single most valuable detail right now.
- **Did the toggle actually clear the freeze?** Negative results are just as
  valuable.
- Resolution and refresh rate, and whether lowering either changes anything.
- Does it only happen after **suspend/resume**, or on an idle screen?
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
