#!/usr/bin/env bash
# fw12powersave installer — apply the idle-power fixes for Framework 12 + Hyprland.
#   1. hypridle: lock + display OFF on idle, suspend(-then-hibernate) when away
#   2. S3 ("deep") suspend via a tmpfiles.d rule
#   3. (optional) suspend-then-hibernate: S3 first, auto-hibernate after a delay
# Reversible: see uninstall.sh.  Overridable via env:
#   SCREENOFF_SEC (default 90)   SUSPEND_SEC (default 600)
#   HIBERNATE (auto|1|0, default auto)   HIBERNATE_DELAY (default 90min)
set -euo pipefail

SCREENOFF_SEC="${SCREENOFF_SEC:-90}"
SUSPEND_SEC="${SUSPEND_SEC:-600}"
HIBERNATE="${HIBERNATE:-auto}"
HIBERNATE_DELAY="${HIBERNATE_DELAY:-90min}"
LOCK_SEC="$SCREENOFF_SEC"
DPMS_SEC=$((SCREENOFF_SEC + 3))
HYPRIDLE_CONF="$HOME/.config/hypr/hypridle.conf"
TMPFILE_RULE="/etc/tmpfiles.d/fw12-s3-deep.conf"
SLEEP_DROPIN="/etc/systemd/sleep.conf.d/fw12-hibernate-delay.conf"

say(){ printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v hypridle >/dev/null || die "hypridle not found — install it first (Hyprland idle daemon)."

# Lock/wake commands: prefer Omarchy's, fall back to generic.
if command -v omarchy-system-lock >/dev/null 2>&1; then
    LOCK_CMD="omarchy-system-lock"
    BEFORE_SLEEP="OMARCHY_LOCK_ONLY=true omarchy-system-lock"
    AFTER_SLEEP="sleep 1 && omarchy-system-wake"
    say "Detected Omarchy — using omarchy-system-lock."
else
    LOCK_CMD="loginctl lock-session"
    BEFORE_SLEEP="loginctl lock-session"
    AFTER_SLEEP="hyprctl dispatch dpms on"
    say "No Omarchy — using loginctl lock-session."
fi

# Decide suspend vs suspend-then-hibernate.
hib_ready(){ grep -qw disk /sys/power/state 2>/dev/null && grep -q 'resume=' /proc/cmdline 2>/dev/null; }
SUSPEND_ACTION="systemctl suspend"
WRITE_DROPIN=0
case "$HIBERNATE" in
    0) say "Hibernation disabled (HIBERNATE=0) — plain S3 suspend." ;;
    1) if hib_ready; then SUSPEND_ACTION="systemctl suspend-then-hibernate"; WRITE_DROPIN=1
       else warn "HIBERNATE=1 but system not hibernate-ready (need 'disk' in /sys/power/state + resume= on cmdline) — using plain suspend."; fi ;;
    *) if hib_ready; then SUSPEND_ACTION="systemctl suspend-then-hibernate"; WRITE_DROPIN=1; say "Hibernation looks ready — using suspend-then-hibernate."
       else warn "No hibernate support detected — using plain S3 suspend (set up swap+resume= to enable)."; fi ;;
esac

# --- 1. hypridle config ------------------------------------------------------
mkdir -p "$(dirname "$HYPRIDLE_CONF")"
[ -f "$HYPRIDLE_CONF" ] && { bak="$HYPRIDLE_CONF.bak.$(date +%s)"; cp "$HYPRIDLE_CONF" "$bak"; say "Backed up hypridle.conf -> $bak"; }

cat > "$HYPRIDLE_CONF" <<EOF
# Managed by fw12powersave (https://github.com/mechanicsunlocked/fw12powersave)
general {
    lock_cmd = $LOCK_CMD
    before_sleep_cmd = $BEFORE_SLEEP
    after_sleep_cmd = $AFTER_SLEEP
    inhibit_sleep = 3
    # ignore_*_inhibit left default (false) so video players keep the screen awake.
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

# After ${SUSPEND_SEC}s idle (locks first via before_sleep_cmd).
listener {
    timeout = $SUSPEND_SEC
    on-timeout = $SUSPEND_ACTION
}
EOF
say "Wrote $HYPRIDLE_CONF  (off @ ${SCREENOFF_SEC}s, '$SUSPEND_ACTION' @ ${SUSPEND_SEC}s)"

# --- 2. S3 deep suspend ------------------------------------------------------
if grep -qw deep /sys/power/mem_sleep 2>/dev/null; then
    printf '# fw12powersave: use S3 (deep) suspend instead of s2idle\nw /sys/power/mem_sleep - - - - deep\n' \
        | sudo tee "$TMPFILE_RULE" >/dev/null
    sudo systemd-tmpfiles --create "$TMPFILE_RULE" >/dev/null 2>&1 || echo deep | sudo tee /sys/power/mem_sleep >/dev/null
    say "Enabled S3 deep suspend -> $TMPFILE_RULE  (now: $(cat /sys/power/mem_sleep))"
else
    warn "BIOS does not advertise 'deep' in /sys/power/mem_sleep — skipping S3 (staying on s2idle)."
fi

# --- 3. suspend-then-hibernate delay ----------------------------------------
if [ "$WRITE_DROPIN" = 1 ]; then
    sudo mkdir -p "$(dirname "$SLEEP_DROPIN")"
    printf '# fw12powersave: S3 first, then hibernate after this delay.\n[Sleep]\nHibernateDelaySec=%s\n' "$HIBERNATE_DELAY" \
        | sudo tee "$SLEEP_DROPIN" >/dev/null
    sudo systemctl daemon-reload 2>/dev/null || true
    say "Set suspend-then-hibernate delay -> $SLEEP_DROPIN (HibernateDelaySec=$HIBERNATE_DELAY)"
    warn "TEST 'systemctl hibernate' resumes cleanly before trusting auto-hibernate."
fi

# --- restart hypridle --------------------------------------------------------
if command -v hyprctl >/dev/null 2>&1; then
    pkill -x hypridle 2>/dev/null || true; sleep 1
    hyprctl dispatch exec hypridle >/dev/null 2>&1 || true
    say "Restarted hypridle."
else
    warn "hyprctl not on PATH — restart hypridle manually (or re-login)."
fi

echo
say "Done. Idle (screen off) ~1.3-1.8W; away -> S3 then hibernate. Tune in $HYPRIDLE_CONF."
