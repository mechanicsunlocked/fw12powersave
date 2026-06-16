#!/usr/bin/env bash
# fw12powersave installer — Framework 12 idle-power + sleep tuning.
#   1. Idle: hypridle lock + display OFF (the big battery win)
#   2. Away: HIBERNATE on idle + lid-close, and MASK suspend
#      (on FW12 suspend/s2idle/S3 breaks the cros-ec accelerometer — see README)
# Reversible: see uninstall.sh.  Env overrides:
#   SCREENOFF_SEC (default 90)  AWAY_SEC (default 600)  NO_HIBERNATE=1 (idle-only, leave suspend alone)
set -euo pipefail

SCREENOFF_SEC="${SCREENOFF_SEC:-90}"
AWAY_SEC="${AWAY_SEC:-600}"
LOCK_SEC="$SCREENOFF_SEC"
DPMS_SEC=$((SCREENOFF_SEC + 3))
HYPRIDLE_CONF="$HOME/.config/hypr/hypridle.conf"
LID_DROPIN="/etc/systemd/logind.conf.d/fw12-lid-hibernate.conf"

say(){ printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v hypridle >/dev/null || die "hypridle not found — install it first."

# lock/wake commands: prefer Omarchy's, else generic
if command -v omarchy-system-lock >/dev/null 2>&1; then
    LOCK_CMD="omarchy-system-lock"; BEFORE_SLEEP="OMARCHY_LOCK_ONLY=true omarchy-system-lock"; AFTER_SLEEP="sleep 1 && omarchy-system-wake"
    say "Detected Omarchy — using omarchy-system-lock."
else
    LOCK_CMD="loginctl lock-session"; BEFORE_SLEEP="loginctl lock-session"; AFTER_SLEEP="hyprctl dispatch dpms on"
    say "No Omarchy — using loginctl lock-session."
fi

# hibernate decision
hib_ready(){ grep -qw disk /sys/power/state 2>/dev/null && grep -q 'resume=' /proc/cmdline 2>/dev/null; }
USE_HIB=1
if [ "${NO_HIBERNATE:-0}" = 1 ]; then USE_HIB=0; say "NO_HIBERNATE set — idle-only, leaving suspend untouched."
elif ! hib_ready; then USE_HIB=0; warn "Not hibernate-ready (need 'disk' in /sys/power/state + resume= on cmdline). Idle-only; set up swap+resume to enable hibernate."
else say "Hibernate-ready — will use hibernate for away + lid-close, and mask suspend."; fi

# remove any stale artifacts a previous (S3-era) version may have installed
sudo rm -f /etc/tmpfiles.d/fw12-s3-deep.conf \
           /usr/lib/systemd/system-sleep/50-fw12-cros-ec-accel \
           /etc/systemd/sleep.conf.d/fw12-hibernate-delay.conf 2>/dev/null || true

# --- hypridle config ---------------------------------------------------------
mkdir -p "$(dirname "$HYPRIDLE_CONF")"
[ -f "$HYPRIDLE_CONF" ] && { bak="$HYPRIDLE_CONF.bak.$(date +%s)"; cp "$HYPRIDLE_CONF" "$bak"; say "Backed up hypridle.conf -> $bak"; }

{
cat <<EOF
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

# Display OFF just after locking — the real power win (package PC2/PC3 ~2.95W ->
# PC6/PC8 ~1.8W, backlight off).
listener {
    timeout = $DPMS_SEC
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}
EOF
if [ "$USE_HIB" = 1 ]; then
cat <<EOF

# Away after ${AWAY_SEC}s -> HIBERNATE (NOT suspend: suspend kills the cros-ec
# accelerometer on FW12; hibernate's full re-probe revives it + zero power).
listener {
    timeout = $AWAY_SEC
    on-timeout = systemctl hibernate
}
EOF
fi
} > "$HYPRIDLE_CONF"
say "Wrote $HYPRIDLE_CONF"

# --- suspend off + hibernate on + lid->hibernate -----------------------------
if [ "$USE_HIB" = 1 ]; then
    sudo systemctl unmask sleep.target hibernate.target >/dev/null 2>&1 || true
    sudo systemctl mask suspend.target suspend-then-hibernate.target >/dev/null 2>&1 || true
    say "Masked suspend.target + suspend-then-hibernate.target; hibernate enabled."
    sudo mkdir -p "$(dirname "$LID_DROPIN")"
    sudo tee "$LID_DROPIN" >/dev/null <<'EOF'
# fw12powersave: hibernate on lid close (suspend is masked — it breaks the
# cros-ec accelerometer on this machine; hibernate revives it on resume).
[Login]
HandleLidSwitch=hibernate
HandleLidSwitchExternalPower=hibernate
HandleLidSwitchDocked=ignore
EOF
    say "Lid close -> hibernate ($LID_DROPIN); applies next login."
    warn "TEST 'systemctl hibernate' resumes cleanly once before trusting auto-hibernate."
fi

# --- restart hypridle --------------------------------------------------------
if command -v hyprctl >/dev/null 2>&1; then
    pkill -x hypridle 2>/dev/null || true; sleep 1
    hyprctl dispatch exec hypridle >/dev/null 2>&1 || true
    say "Restarted hypridle."
else
    warn "hyprctl not on PATH — restart hypridle manually."
fi

echo
say "Done. Idle (screen off) ~1.7W. Away/lid -> hibernate. Suspend is OFF on purpose."
