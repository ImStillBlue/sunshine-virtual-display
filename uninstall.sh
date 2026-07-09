#!/usr/bin/env bash
# Sunveil uninstaller.
# Removes the hooks, the global_prep_cmd entry, the systemd override, and the
# kwin-capture settings Sunveil added — restoring your most recent Sunshine
# config backup where possible. Does NOT uninstall the krfb package (other
# things may use it); it just tells you how if you want to.

set -euo pipefail

SUNSHINE_DIR="$HOME/.config/sunshine"
CONF="$SUNSHINE_DIR/sunshine.conf"
HOOKDIR="$SUNSHINE_DIR/hooks"
SERVICE="app-dev.lizardbyte.app.Sunshine.service"
OVERRIDE_DIR="$HOME/.config/systemd/user/${SERVICE}.d"
OVERRIDE="$OVERRIDE_DIR/sunveil.conf"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

say "Sunveil uninstaller"

# --- restore the newest Sunveil config backup, if one exists -------------------
newest_bak="$(ls -1t "$SUNSHINE_DIR"/sunshine.conf.sunveil-bak.* 2>/dev/null | head -n1 || true)"
if [ -n "${newest_bak:-}" ] && [ -f "$newest_bak" ]; then
  cp -f "$CONF" "$CONF.pre-uninstall.$(date +%s)" 2>/dev/null || true
  cp -f "$newest_bak" "$CONF"
  say "Restored Sunshine config from backup: $(basename "$newest_bak")"
else
  warn "No Sunveil config backup found; leaving sunshine.conf as-is."
  warn "You may want to manually clear: capture, output_name, global_prep_cmd."
fi

# --- remove the systemd override -----------------------------------------------
if [ -f "$OVERRIDE" ]; then
  rm -f "$OVERRIDE"
  rmdir "$OVERRIDE_DIR" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  say "Removed systemd override."
fi

# --- remove the hook files (keep any hook.log the user might want) -------------
if [ -d "$HOOKDIR" ]; then
  rm -f "$HOOKDIR/stream-start.sh" "$HOOKDIR/stream-end.sh" "$HOOKDIR/sunveil.conf"
  rm -rf "$HOOKDIR/state"
  say "Removed hook scripts (kept hook.log if present)."
fi

# --- restart Sunshine into the restored config ---------------------------------
if systemctl --user is-enabled "$SERVICE" >/dev/null 2>&1; then
  systemctl --user restart "$SERVICE" 2>/dev/null || true
  say "Restarted Sunshine."
fi

cat <<EOF

Sunveil removed.

Left in place (remove manually if you want):
  * krfb package         ->  sudo pacman -Rns krfb
  * hook.log             ->  $HOOKDIR/hook.log
  * autologin (if you added it) -> /etc/sddm.conf.d/autologin.conf

EOF
