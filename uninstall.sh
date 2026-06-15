#!/usr/bin/env bash
# fw12powersave uninstaller — revert what install.sh changed.
set -euo pipefail
HYPRIDLE_CONF="$HOME/.config/hypr/hypridle.conf"
TMPFILE_RULE="/etc/tmpfiles.d/fw12-s3-deep.conf"
say(){ printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# Restore newest hypridle backup if present.
newest_bak=$(ls -t "$HYPRIDLE_CONF".bak.* 2>/dev/null | head -1 || true)
if [ -n "$newest_bak" ]; then
    cp "$newest_bak" "$HYPRIDLE_CONF"
    say "Restored hypridle.conf from $newest_bak"
else
    warn "No backup found; leaving $HYPRIDLE_CONF as-is (edit or 'omarchy refresh config hypr/hypridle.conf')."
fi

# Remove S3 rule and revert to s2idle now.
if [ -f "$TMPFILE_RULE" ]; then
    sudo rm -f "$TMPFILE_RULE"
    say "Removed $TMPFILE_RULE"
fi
if grep -qw s2idle /sys/power/mem_sleep 2>/dev/null; then
    echo s2idle | sudo tee /sys/power/mem_sleep >/dev/null
    say "Reverted current mem_sleep -> $(cat /sys/power/mem_sleep)"
fi

# Restart hypridle.
if command -v hyprctl >/dev/null 2>&1; then
    pkill -x hypridle 2>/dev/null || true; sleep 1
    hyprctl dispatch exec hypridle >/dev/null 2>&1 || true
    say "Restarted hypridle."
fi
say "Uninstalled."
