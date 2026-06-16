#!/usr/bin/env bash
# fw12powersave uninstaller — revert what install.sh changed.
set -euo pipefail
HYPRIDLE_CONF="$HOME/.config/hypr/hypridle.conf"
LID_DROPIN="/etc/systemd/logind.conf.d/fw12-lid-hibernate.conf"
say(){ printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# Restore newest hypridle backup if present.
newest_bak=$(ls -t "$HYPRIDLE_CONF".bak.* 2>/dev/null | head -1 || true)
if [ -n "$newest_bak" ]; then cp "$newest_bak" "$HYPRIDLE_CONF"; say "Restored hypridle.conf from $newest_bak"
else warn "No hypridle backup found; leaving $HYPRIDLE_CONF (or run: omarchy refresh config hypr/hypridle.conf)."; fi

# Re-enable suspend (undo the mask) and drop the lid override.
sudo systemctl unmask suspend.target suspend-then-hibernate.target >/dev/null 2>&1 || true
say "Unmasked suspend.target + suspend-then-hibernate.target."
if [ -f "$LID_DROPIN" ]; then sudo rm -f "$LID_DROPIN"; sudo systemctl daemon-reload 2>/dev/null || true; say "Removed $LID_DROPIN."; fi

# Clean any stale S3-era artifacts too.
sudo rm -f /etc/tmpfiles.d/fw12-s3-deep.conf \
           /usr/lib/systemd/system-sleep/50-fw12-cros-ec-accel \
           /etc/systemd/sleep.conf.d/fw12-hibernate-delay.conf 2>/dev/null || true

# Restart hypridle.
if command -v hyprctl >/dev/null 2>&1; then
    pkill -x hypridle 2>/dev/null || true; sleep 1
    hyprctl dispatch exec hypridle >/dev/null 2>&1 || true
    say "Restarted hypridle."
fi
warn "Note: suspend on FW12 still breaks the accelerometer — re-enabling it brings that back."
say "Uninstalled."
