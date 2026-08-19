#!/usr/bin/env bash
#
# monitor-toggle.sh
#
# Turns a single monitor off under GNOME (exactly like the switch in
# Settings -> Displays), waits a moment, then turns it back on in its
# previous state.
#
# Works on Wayland and X11. Talks to org.gnome.Mutter.DisplayConfig, the
# same interface used by gdctl and the Settings panel.
#
# The change is applied as "temporary", so nothing is written to your
# persistent monitor configuration. Aborting with Ctrl+C still restores
# the monitor.
#
# ---------------------------------------------------------------------------
# WHAT THIS IS FOR
# ---------------------------------------------------------------------------
# On some AMD systems the display pipeline wedges. The journal then shows
# something like:
#
#     amdgpu 0000:c4:00.0: [drm] *ERROR* [CRTC:428:crtc-1] flip_done timed out
#
# No GPU reset, no ring timeout -- the GPU keeps computing, only the picture
# is stuck. Briefly disabling and re-enabling the affected output rebuilds
# the pipeline and clears the freeze.
#
# That is what this script is for. You run it AFTER a freeze; it does not
# prevent one. It is a workaround, not a fix.
#
# To check whether you have this particular problem:
#
#     journalctl -b -1 -k | grep -E "flip_done|GPU reset|ring .*timeout"
#
# If you see flip_done WITHOUT an accompanying GPU reset, this script may
# help you.
#
# NOTE ON THE CAUSE: it is NOT established that this is an amdgpu bug. The
# failure surfaces in amdgpu's display code, but the only machine it has been
# reproduced on drives its monitors through a Thunderbolt dock, over MST,
# with DSC, on a bandwidth-saturated USB4 link -- any of which could be the
# real trigger. See the README for the evidence and for how to help narrow
# it down.
#
# ---------------------------------------------------------------------------
# WHY TARGETS ARE MATCHED BY MODEL NAME, NOT DP NUMBER
# ---------------------------------------------------------------------------
# DP connector numbers are NOT stable. They shift when cables are replugged
# or depending on enumeration order. A shortcut here pointed at DP-4/DP-5
# for a long time; after a renumbering the outputs were called DP-6/DP-7.
# The script then aborted with "monitor 'DP-4' not found".
#
# That failure mode is nastier than it sounds: the workaround appears to do
# nothing, so the freeze looks like it has a brand-new cause. It cost hours
# of chasing the wrong lead.
#
# So <MONITOR> also accepts the model/vendor name (substring, case
# insensitive). That stays the same across replugs.
#
# ---------------------------------------------------------------------------
# HOW TO FIND THE NAMES
# ---------------------------------------------------------------------------
#   ./monitor-toggle.sh --list   <- connector, active/inactive, model name
#   gdctl show                   <- GNOME's own tool, more detail
#                                   (vendor, product, serial, modes)
#
# xrandr is NOT reliable here. Under Wayland it only runs through XWayland
# and reports just the currently ACTIVE outputs, without model names --
# inactive outputs such as eDP-1 with the lid closed are missing entirely.
# "xrandr --listmonitors" is therefore useless for this purpose.
#
# ---------------------------------------------------------------------------
# DO NOT PICK A VERY SHORT DURATION
# ---------------------------------------------------------------------------
# Keep the off-time at roughly 3 seconds or more. Monitors that enter
# standby on signal loss may refuse a signal that comes back too quickly and
# simply stay dark -- then only switching the input source or power-cycling
# the monitor brings it back. The default of 5 seconds is a safe choice.
#
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME <MONITOR> [SECONDS]   Disable MONITOR, re-enable it after SECONDS
  $SCRIPT_NAME --list                List available monitors

  <MONITOR>    Connector name (DP-1, HDMI-1, eDP-1) OR model/vendor name
               (e.g. "Odyssey G70D"). The model name is more robust because
               DP numbering can shift when cables are replugged.
  [SECONDS]    Wait time, default: 5. Values below 3 are risky -- some
               monitors will not wake back up from standby.

Examples:
  $SCRIPT_NAME --list
  $SCRIPT_NAME "Odyssey G70D"
  $SCRIPT_NAME HDMI-1 10

Finding the names:
  "$SCRIPT_NAME --list"
      connector + active/inactive + model name
  "gdctl show"
      more detail: vendor, product, serial, modes

  xrandr is not suitable: under Wayland it shows only the active outputs and
  no model names -- inactive ones such as eDP-1 are missing entirely.
EOF
}

ACTION="toggle"
TARGET="${1:-}"
DURATION="${2:-5}"

if [[ -z "$TARGET" || "$TARGET" == "-h" || "$TARGET" == "--help" ]]; then
  usage
  exit 0
fi
if [[ "$TARGET" == "--list" || "$TARGET" == "-l" ]]; then
  ACTION="list"
  TARGET=""
fi

# Only one toggle at a time. A second instance started during the off-window
# would snapshot the DISABLED state as its restore target and re-apply it
# after the first instance has already restored -- leaving the monitor off
# for good. Easy to trigger by pressing the shortcut twice during a freeze.
if [[ "$ACTION" == "toggle" ]]; then
  LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/monitor-toggle.lock"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "Error: another $SCRIPT_NAME run is already in progress." >&2
    exit 1
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required but was not found." >&2
  exit 1
fi

python3 - "$ACTION" "$TARGET" "$DURATION" <<'PYEOF'
import sys, time

try:
    import gi
    from gi.repository import Gio, GLib
except Exception:
    sys.stderr.write(
        "Error: PyGObject is required.\n"
        "  Fedora:        sudo dnf install python3-gobject\n"
        "  Debian/Ubuntu: sudo apt install python3-gi\n"
        "  Arch:          sudo pacman -S python-gobject\n"
    )
    sys.exit(1)

action   = sys.argv[1] if len(sys.argv) > 1 else "toggle"
target   = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    duration = float(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else 5.0
except ValueError:
    sys.stderr.write("Error: SECONDS must be a number.\n")
    sys.exit(1)

BUS_NAME = "org.gnome.Mutter.DisplayConfig"
OBJ_PATH = "/org/gnome/Mutter/DisplayConfig"
IFACE    = "org.gnome.Mutter.DisplayConfig"
APPLY_TEMPORARY = 1  # 0=verify, 1=temporary, 2=persistent

# Never wait forever: this script runs while the display stack is already
# misbehaving. If mutter does not answer, hanging here would just stack up
# stuck processes with every further trigger press.
DBUS_TIMEOUT_MS = 15000

try:
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
except Exception:
    sys.stderr.write("Error: cannot connect to the session D-Bus.\n")
    sys.exit(1)


def get_state():
    try:
        res = bus.call_sync(
            BUS_NAME, OBJ_PATH, IFACE, "GetCurrentState",
            None, None, Gio.DBusCallFlags.NONE, DBUS_TIMEOUT_MS, None,
        )
    except GLib.Error as e:
        sys.stderr.write(
            "Error: the GNOME display service is unreachable.\n"
            "Is a GNOME session (mutter) running?\nDetails: %s\n" % e.message
        )
        sys.exit(1)
    # (serial, monitors, logical_monitors, properties)
    return res.unpack()


serial, monitors, logical_monitors, props = get_state()

# connector -> currently active mode id, plus a list of all monitors
mode_map = {}              # connector -> current mode id
dims_map = {}              # connector -> (width, height) of the current mode
pref_map = {}              # connector -> (preferred mode id, preferred scale)
all_monitors = []          # (connector, vendor, product)
active_conns = set()

for mon in monitors:
    spec = mon[0]          # (connector, vendor, product, serial)
    conn = spec[0]
    all_monitors.append((conn, spec[1], spec[2]))
    for mode in mon[1]:    # (id, w, h, refresh, pref_scale, [scales], props)
        if mode[6].get("is-current"):
            mode_map[conn] = mode[0]
            dims_map[conn] = (mode[1], mode[2])
        if mode[6].get("is-preferred"):
            pref_map[conn] = (mode[0], mode[4])

for lm in logical_monitors:
    for mspec in lm[5]:    # (connector, vendor, product, serial)
        active_conns.add(mspec[0])


def label_of(vendor, product):
    return " ".join(x for x in (vendor, product) if x).strip()


if action == "list":
    print("Available monitors:")
    for conn, vendor, product in all_monitors:
        state = "active  " if conn in active_conns else "inactive"
        label = label_of(vendor, product)
        extra = "  (%s)" % label if label else ""
        print("  %-12s %s%s" % (conn, state, extra))
    sys.exit(0)


def resolve_target(spec):
    """Resolve a target specification to a connector name.

    Accepts a connector name (DP-7) or a model/vendor name (substring, case
    insensitive). Model names are more robust than connector numbers, which
    can shift when cables are replugged.
    """
    for conn, _vendor, _product in all_monitors:
        if conn == spec:
            return conn

    needle = spec.casefold()
    hits = [conn for conn, vendor, product in all_monitors
            if needle in label_of(vendor, product).casefold()]
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        sys.stderr.write(
            "Error: '%s' matches several monitors: %s\n" % (spec, ", ".join(hits))
        )
        sys.exit(1)

    sys.stderr.write("Error: monitor '%s' not found.\n" % spec)
    sys.stderr.write("Available: %s\n" % ", ".join(
        "%s (%s)" % (c, label_of(v, p)) if label_of(v, p) else c
        for c, v, p in all_monitors
    ))
    sys.exit(1)


target_conn = resolve_target(target)

layout_mode = props.get("layout-mode")


def build_lms(skip=None):
    """Build the logical-monitor list from the current state.
    skip = connector to leave out (None = keep everything)."""
    out = []
    for lm in logical_monitors:
        x, y, scale, transform, primary = lm[0], lm[1], lm[2], lm[3], lm[4]
        conns = [m[0] for m in lm[5] if m[0] != skip]
        if not conns:
            continue
        mons = [(c, mode_map[c], {}) for c in conns]
        out.append([int(x), int(y), float(scale), int(transform),
                    bool(primary), mons])
    return out


restore_lms = build_lms()
disable_lms = build_lms(skip=target_conn)

if not disable_lms:
    sys.stderr.write(
        "Error: '%s' is the only active monitor and cannot be disabled.\n"
        % target_conn
    )
    sys.exit(1)

# at least one primary monitor has to remain
if not any(d[4] for d in disable_lms):
    disable_lms[0][4] = True

# move the remaining monitors to the origin (avoids gaps in the layout)
minx = min(d[0] for d in disable_lms)
miny = min(d[1] for d in disable_lms)
for d in disable_lms:
    d[0] -= minx
    d[1] -= miny


def to_variant_lms(lms):
    out = []
    for d in lms:
        mons = [(str(c), str(mid), {}) for (c, mid, _p) in d[5]]
        out.append((int(d[0]), int(d[1]), float(d[2]), int(d[3]),
                    bool(d[4]), mons))
    return out


def apply(cur_serial, lms):
    p = {}
    if layout_mode is not None:
        p["layout-mode"] = GLib.Variant("u", layout_mode)
    args = GLib.Variant(
        "(uua(iiduba(ssa{sv}))a{sv})",
        (cur_serial, APPLY_TEMPORARY, to_variant_lms(lms), p),
    )
    bus.call_sync(
        BUS_NAME, OBJ_PATH, IFACE, "ApplyMonitorsConfig",
        args, None, Gio.DBusCallFlags.NONE, DBUS_TIMEOUT_MS, None,
    )


def restore():
    # fetch a fresh serial -- it changes after every apply
    fresh_serial, fresh_monitors, _lms, _props = get_state()
    try:
        apply(fresh_serial, restore_lms)
        return
    except GLib.Error as first_err:
        # Connectors can be renumbered while the monitor is off -- MST docks
        # do this (DP-4/DP-5 became DP-6/DP-7 on the reference system). The
        # snapshot then references stale connector names and mode ids.
        # Re-resolve everything by model label and retry once.
        label_by_conn = {c: label_of(v, p) for c, v, p in all_monitors}
        conn_by_label = {}
        fresh_mode = {}
        for mon in fresh_monitors:
            spec = mon[0]
            conn_by_label.setdefault(label_of(spec[1], spec[2]), spec[0])
            cur = pref = None
            for mode in mon[1]:
                if mode[6].get("is-current"):
                    cur = mode[0]
                if mode[6].get("is-preferred"):
                    pref = mode[0]
            fresh_mode[spec[0]] = cur if cur is not None else pref
        remapped = []
        for d in restore_lms:
            mons = []
            for c, _mid, _p in d[5]:
                nc = conn_by_label.get(label_by_conn.get(c, ""), c)
                if fresh_mode.get(nc) is None:
                    raise first_err
                mons.append((nc, fresh_mode[nc], {}))
            remapped.append([d[0], d[1], d[2], d[3], d[4], mons])
        apply(get_state()[0], remapped)


if target_conn not in active_conns:
    # The monitor is already off -- e.g. an earlier run died between disable
    # and restore. Enabling it is the useful thing to do here, not an error.
    if target_conn not in pref_map:
        sys.stderr.write(
            "Error: '%s' is inactive and reports no preferred mode to "
            "enable it with.\n" % target_conn
        )
        sys.exit(1)
    pref_mode, pref_scale = pref_map[target_conn]

    def lm_width(lm):
        w, h = dims_map[lm[5][0][0]]
        if int(lm[3]) in (1, 3, 5, 7):   # 90/270 degree transforms
            w = h
        if layout_mode != 2:             # logical layout: scale applies
            w = round(w / float(lm[2]))
        return w

    lms = build_lms()
    rightmost = max(lms, key=lambda lm: lm[0] + lm_width(lm))
    new_x = rightmost[0] + lm_width(rightmost)
    lms.append([new_x, rightmost[1], float(pref_scale), 0, False,
                [(target_conn, pref_mode, {})]])
    try:
        apply(serial, lms)
    except GLib.Error as e:
        sys.stderr.write(
            "Error enabling %s: %s\n"
            "Enable it manually via GNOME Settings -> Displays.\n"
            % (target_conn, e.message)
        )
        sys.exit(1)
    print("%s was already off -- re-enabled it at its preferred mode "
          "(temporary, placed right of the current layout)." % target_conn)
    sys.exit(0)

disabled = False
restored = False
try:
    print("Disabling %s for %g second(s) ..." % (target_conn, duration))
    apply(serial, disable_lms)
    disabled = True
    time.sleep(duration)
except KeyboardInterrupt:
    print("\nAborted -- restoring the previous state ...")
except GLib.Error as e:
    sys.stderr.write("Error applying the configuration: %s\n" % e.message)
finally:
    if disabled:
        try:
            restore()
            restored = True
            print("Re-enabling %s." % target_conn)
        except GLib.Error as e:
            sys.stderr.write(
                "Error restoring %s: %s\n"
                "Re-enable it via GNOME Settings -> Displays, or run this "
                "script again (an inactive target gets enabled).\n"
                % (target_conn, e.message)
            )

sys.exit(0 if (disabled and restored) else 1)
PYEOF
