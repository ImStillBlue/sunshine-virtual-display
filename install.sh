#!/usr/bin/env bash
# Sunveil installer — on-demand headless virtual display for Sunshine on CachyOS
# (KDE Plasma 6 Wayland). Safe to run on an existing Sunshine install and safe to
# re-run (idempotent). It never overwrites your Sunshine config blindly: it backs
# it up and merges only the keys it needs.
#
#   Usage:  ./install.sh [--coexist] [--no-restart] [--yes]
#
#     --coexist     Keep physical monitors ON (extend mode) instead of the
#                   default "monitors off while streaming".
#     --no-restart  Don't restart the Sunshine service at the end.
#     --yes         Non-interactive; assume yes to prompts.

set -euo pipefail

# ------------------------------------------------------------------ pretty output
c_hd=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_wn=$'\033[1;33m'; c_er=$'\033[1;31m'; c_z=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_hd" "$c_z" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$c_ok" "$c_z" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$c_wn" "$c_z" "$*"; }
die()  { printf '%s[x]%s %s\n'  "$c_er" "$c_z" "$*" >&2; exit 1; }

# ------------------------------------------------------------------ args
DISABLE_PHYSICAL=true
DO_RESTART=true
ASSUME_YES=false
for a in "$@"; do
  case "$a" in
    --coexist)    DISABLE_PHYSICAL=false ;;
    --no-restart) DO_RESTART=false ;;
    --yes|-y)     ASSUME_YES=true ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' | head -n 16; exit 0 ;;
    *) die "Unknown argument: $a (try --help)" ;;
  esac
done

ask() { # ask "question" -> returns 0 for yes
  $ASSUME_YES && return 0
  local reply; read -r -p "$1 [Y/n] " reply || true
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUNSHINE_DIR="$HOME/.config/sunshine"
CONF="$SUNSHINE_DIR/sunshine.conf"
HOOKDIR="$SUNSHINE_DIR/hooks"
SERVICE="app-dev.lizardbyte.app.Sunshine.service"

say "Sunveil installer"
echo

# ------------------------------------------------------------------ 1. sanity checks
[ "$(id -u)" -ne 0 ] || die "Run as your normal user, NOT root/sudo. (It edits your ~/.config and user service.)"

command -v sunshine >/dev/null 2>&1 || die "Sunshine not found. Install it first (e.g. 'sudo pacman -S sunshine')."

# Wayland + KDE check (warn, don't hard-fail — advanced users may know better)
if [ "${XDG_SESSION_TYPE:-}" != "wayland" ]; then
  warn "Session type is '${XDG_SESSION_TYPE:-unknown}', not 'wayland'. Sunveil needs KDE Plasma on Wayland."
  ask "Continue anyway?" || exit 1
fi
if ! command -v kscreen-doctor >/dev/null 2>&1; then
  warn "kscreen-doctor not found — needed to manage displays. Will install 'kscreen'."
fi

# ------------------------------------------------------------------ 2. dependencies
need_pkgs=()
command -v krfb-virtualmonitor >/dev/null 2>&1 || need_pkgs+=(krfb)
command -v kscreen-doctor       >/dev/null 2>&1 || need_pkgs+=(kscreen)

if [ "${#need_pkgs[@]}" -gt 0 ]; then
  say "Need to install: ${need_pkgs[*]}"
  if command -v pacman >/dev/null 2>&1; then
    if ask "Install with pacman now? (needs sudo)"; then
      sudo pacman -S --needed "${need_pkgs[@]}" || die "Package install failed."
    else
      die "Cannot continue without: ${need_pkgs[*]}"
    fi
  else
    die "pacman not found. This installer targets CachyOS/Arch. Install manually: ${need_pkgs[*]}"
  fi
else
  ok "Dependencies present (krfb, kscreen)."
fi

command -v krfb-virtualmonitor >/dev/null 2>&1 || die "krfb-virtualmonitor still missing after install."

# ------------------------------------------------------------------ 3. deploy hooks
say "Installing hooks into $HOOKDIR"
mkdir -p "$HOOKDIR"
install -m 0755 "$SCRIPT_DIR/hooks/stream-start.sh" "$HOOKDIR/stream-start.sh"
install -m 0755 "$SCRIPT_DIR/hooks/stream-end.sh"   "$HOOKDIR/stream-end.sh"

# config: don't clobber an existing sunveil.conf (preserve user's tuning)
if [ -f "$HOOKDIR/sunveil.conf" ]; then
  ok "Kept existing hooks/sunveil.conf (not overwritten)."
  # but still honor the --coexist flag by patching DISABLE_PHYSICAL
  sed -i "s/^DISABLE_PHYSICAL=.*/DISABLE_PHYSICAL=$DISABLE_PHYSICAL/" "$HOOKDIR/sunveil.conf"
else
  install -m 0644 "$SCRIPT_DIR/hooks/sunveil.conf" "$HOOKDIR/sunveil.conf"
  sed -i "s/^DISABLE_PHYSICAL=.*/DISABLE_PHYSICAL=$DISABLE_PHYSICAL/" "$HOOKDIR/sunveil.conf"
fi
# discover the VM name from the (possibly user-edited) config
VM_NAME="$(grep -E '^VM_NAME=' "$HOOKDIR/sunveil.conf" | head -1 | cut -d'"' -f2)"
VM_NAME="${VM_NAME:-sunshine-vm}"
VM_OUTPUT="Virtual-$VM_NAME"
ok "Hooks installed. Virtual output name: $VM_OUTPUT"

# ------------------------------------------------------------------ 4. merge sunshine.conf
say "Configuring $CONF (kwin capture + prep commands)"
mkdir -p "$SUNSHINE_DIR"
touch "$CONF"
BACKUP="$CONF.sunveil-bak.$(date +%s)"
cp -f "$CONF" "$BACKUP"
ok "Backed up current config -> $(basename "$BACKUP")"

DO_HOOK="$HOOKDIR/stream-start.sh"
UNDO_HOOK="$HOOKDIR/stream-end.sh"

# Merge with a tiny Python helper: preserves all other keys/values, only sets
# capture, output_name, and injects/updates our global_prep_cmd entry (keeping
# any prep commands the user already had).
python3 - "$CONF" "$VM_OUTPUT" "$DO_HOOK" "$UNDO_HOOK" <<'PYEOF'
import json, re, sys

conf_path, vm_output, do_hook, undo_hook = sys.argv[1:5]

with open(conf_path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

# Sunshine's config is line-based "key = value"; global_prep_cmd's value is JSON.
kv = {}
order = []
for ln in lines:
    m = re.match(r'\s*([A-Za-z0-9_]+)\s*=\s*(.*)$', ln)
    if m:
        k, v = m.group(1), m.group(2)
        if k not in kv:
            order.append(k)
        kv[k] = v
    # comments / blanks are dropped on rewrite; Sunshine doesn't need them

# our prep entry
our_entry = {"do": do_hook, "undo": undo_hook, "elevated": "false"}

# merge global_prep_cmd: keep existing entries that aren't ours
prep = []
if "global_prep_cmd" in kv and kv["global_prep_cmd"].strip():
    try:
        prep = json.loads(kv["global_prep_cmd"])
        if not isinstance(prep, list):
            prep = []
    except Exception:
        prep = []
# drop any previous sunveil entry so re-running never duplicates it.
# Match either the exact hook paths we're installing now, OR any entry whose
# do/undo basename is our hook scripts (covers a moved install dir).
def is_ours(e):
    if not isinstance(e, dict):
        return False
    do, undo = str(e.get("do", "")), str(e.get("undo", ""))
    if do == do_hook or undo == undo_hook:
        return True
    return do.endswith("/stream-start.sh") or undo.endswith("/stream-end.sh")

prep = [e for e in prep if not is_ours(e)]
prep.append(our_entry)

kv["capture"] = "kwin"
kv["output_name"] = vm_output
kv["global_prep_cmd"] = json.dumps(prep, separators=(",", ":"))

for k in ("capture", "output_name", "global_prep_cmd"):
    if k not in order:
        order.append(k)

with open(conf_path, "w", encoding="utf-8") as f:
    for k in order:
        f.write(f"{k} = {kv[k]}\n")

print("merged")
PYEOF
ok "Set capture=kwin, output_name=$VM_OUTPUT, wired prep commands (existing prep entries preserved)."

# ------------------------------------------------------------------ 5. systemd override (click-race fix)
say "Installing systemd override (waits for KWin before Sunshine starts)"
OVERRIDE_DIR="$HOME/.config/systemd/user/${SERVICE}.d"
mkdir -p "$OVERRIDE_DIR"
install -m 0644 "$SCRIPT_DIR/systemd/override.conf" "$OVERRIDE_DIR/sunveil.conf"
systemctl --user daemon-reload 2>/dev/null || true
ok "Override installed — this fixes the 'cursor moves but clicks do nothing' race on boot."

# ------------------------------------------------------------------ 6. uinput sanity
ME="${USER:-$(id -un)}"
if ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx input; then
  warn "You ($ME) are NOT in the 'input' group. Sunshine needs it to inject mouse/keyboard."
  if ask "Add $ME to the 'input' group now? (needs sudo; re-login required)"; then
    if sudo usermod -aG input "$ME"; then
      warn "Added $ME to 'input'. LOG OUT and back in for it to take effect."
    else
      warn "Could not add to 'input' group; add it manually: sudo usermod -aG input $ME"
    fi
  fi
else
  ok "User is in the 'input' group."
fi

# ------------------------------------------------------------------ 7. restart
if $DO_RESTART; then
  if systemctl --user is-enabled "$SERVICE" >/dev/null 2>&1; then
    say "Restarting Sunshine"
    systemctl --user restart "$SERVICE" || warn "Could not restart; do it manually."
    sleep 2
    systemctl --user is-active "$SERVICE" >/dev/null 2>&1 && ok "Sunshine is running." \
      || warn "Sunshine not active — check: journalctl --user -u $SERVICE -e"
  else
    warn "Sunshine user service not enabled. Enable it with:"
    echo "    systemctl --user enable --now $SERVICE"
  fi
fi

# ------------------------------------------------------------------ done
mode_desc=$([ "$DISABLE_PHYSICAL" = true ] && echo "monitors OFF while streaming" || echo "coexist (monitors stay ON)")
cat <<EOF

$c_ok Sunveil installed.$c_z  Mode: $mode_desc

Next:
  1. Connect from Moonlight/Artemis. A virtual display is created at your
     client's resolution; on disconnect everything is restored.
  2. Debug log (per stream):  tail -f $HOOKDIR/hook.log
  3. Change mode later:       edit $HOOKDIR/sunveil.conf (DISABLE_PHYSICAL=true/false)
  4. Uninstall:               $SCRIPT_DIR/uninstall.sh

Tip: for a truly headless boot (stream a PC that was never logged in), see the
     "Autologin" section in the README.
EOF
