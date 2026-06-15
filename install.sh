#!/usr/bin/env bash
# fw12powersave installer — apply the idle-power fixes for Framework 12 + Hyprland.
#   1. hypridle: lock + display OFF on idle, suspend after a while (inhibitor-aware)
#   2. S3 ("deep") suspend via a tmpfiles.d rule
# Reversible: see uninstall.sh.  Timeouts overridable via env:
#   SCREENOFF_SEC (default 90)  SUSPEND_SEC (default 600)
set -euo pipefail

SCREENOFF_SEC="${SCREENOFF_SEC:-90}"
SUSPEND_SEC="${SUSPEND_SEC:-600}"
LOCK_SEC="$SCREENOFF_SEC"                       # lock together with screen-off
DPMS_SEC=$((SCREENOFF_SEC + 3))                 # blank just after locking
HYPRIDLE_CONF="$HOME/.config/hypr/hypridle.conf"
TMPFILE_RULE="/etc/tmpfiles.d/fw12-s3-deep.conf"

say(){ printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# --- sanity checks -----------------------------------------------------------
command -v hypridle >/dev/null || die "hypridle not found — install it first (Hyprland idle daemon)."
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || command -v hyprctl >/dev/null || warn "Hyprland not detected; config will still be written."

# Pick lock/wake commands: prefer Omarchy's, fall back to generic.
if command -v omarchy-system-lock >/dev/null 2>&1; then
    LOCK_CMD="omarchy-system-lock"
    WAKE_CMD="sleep 1 && omarchy-system-wake"
    BEFORE_SLEEP="OMARCHY_LOCK_ONLY=true omarchy-system-lock"
    AFTER_SLEEP="sleep 1 && omarchy-system-wake"
    say "Detected Omarchy — using omarchy-system-lock."
else
    LOCK_CMD="loginctl lock-session"
    WAKE_CMD="hyprctl dispatch dpms on"
    BEFORE_SLEEP="loginctl lock-session"
    AFTER_SLEEP="hyprctl dispatch dpms on"
    say "No Omarchy — using loginctl lock-session."
fi

# --- 1. hypridle config ------------------------------------------------------
mkdir -p "$(dirname "$HYPRIDLE_CONF")"
if [ -f "$HYPRIDLE_CONF" ]; then
    bak="$HYPRIDLE_CONF.bak.$(date +%s)"
    cp "$HYPRIDLE_CONF" "$bak"
    say "Backed up existing hypridle.conf -> $bak"
fi

cat > "$HYPRIDLE_CONF" <<EOF
# Managed by fw12powersave (https://github.com/mechanicsunlocked/fw12powersave)
# Power-first idle behaviour: lock + display OFF on idle, then S3 suspend.
general {
    lock_cmd = $LOCK_CMD
    before_sleep_cmd = $BEFORE_SLEEP
    after_sleep_cmd = $AFTER_SLEEP
    inhibit_sleep = 3
    # ignore_*_inhibit left at default (false) so video players keep the screen awake.
}

# Lock after ${LOCK_SEC}s idle.
listener {
    timeout = $LOCK_SEC
    on-timeout = $LOCK_CMD
}

# Display fully OFF just after locking — the real power win:
# screen-on pins the SoC package in shallow PC2/PC3 (~2.95W); screen-off lets it
# reach PC6/PC8 (~1.8W) and powers down the backlight.
listener {
    timeout = $DPMS_SEC
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}

# Suspend after ${SUSPEND_SEC}s idle (uses S3 if enabled; locks first via before_sleep_cmd).
listener {
    timeout = $SUSPEND_SEC
    on-timeout = systemctl suspend
}
EOF
say "Wrote $HYPRIDLE_CONF  (lock+off @ ${SCREENOFF_SEC}s, suspend @ ${SUSPEND_SEC}s)"

# --- 2. S3 deep suspend ------------------------------------------------------
if grep -qw deep /sys/power/mem_sleep 2>/dev/null; then
    printf '# fw12powersave: use S3 (deep) suspend instead of s2idle\nw /sys/power/mem_sleep - - - - deep\n' \
        | sudo tee "$TMPFILE_RULE" >/dev/null
    sudo systemd-tmpfiles --create "$TMPFILE_RULE" >/dev/null 2>&1 || echo deep | sudo tee /sys/power/mem_sleep >/dev/null
    say "Enabled S3 deep suspend -> $TMPFILE_RULE  (now: $(cat /sys/power/mem_sleep))"
    warn "TEST RESUME ONCE before trusting auto-suspend:  systemctl suspend  (then power-button to wake)."
else
    warn "This BIOS does not advertise 'deep' in /sys/power/mem_sleep — skipping S3 (staying on s2idle)."
fi

# --- restart hypridle --------------------------------------------------------
if command -v hyprctl >/dev/null 2>&1; then
    pkill -x hypridle 2>/dev/null || true
    sleep 1
    hyprctl dispatch exec hypridle >/dev/null 2>&1 || true
    say "Restarted hypridle."
else
    warn "hyprctl not on PATH — restart hypridle manually (or re-login)."
fi

echo
say "Done. Idle (screen off) should now sit ~1.3–1.8W. Tune timeouts in $HYPRIDLE_CONF."
