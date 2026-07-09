#!/usr/bin/env bash
# Sunveil — Sunshine stream-start hook.
#
# Creates a KWin virtual monitor at the connecting Moonlight client's exact
# resolution/refresh, then (optionally) turns the physical monitors off so the
# stream gets an exclusive headless display. Reverted by stream-end.sh.
#
# Sunshine passes these env vars to prep commands:
#   SUNSHINE_CLIENT_WIDTH, SUNSHINE_CLIENT_HEIGHT, SUNSHINE_CLIENT_FPS
#
# Everything is logged to <hook dir>/hook.log for debugging.

set -uo pipefail

# --- locate ourselves & load config -------------------------------------------
HOOKDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HOOKDIR/hook.log"
STATE="$HOOKDIR/state"
CONF="$HOOKDIR/sunveil.conf"
mkdir -p "$STATE"

# defaults (overridden by sunveil.conf if present)
VM_NAME="sunshine-vm"
DISABLE_PHYSICAL=true
FALLBACK_WIDTH=1920
FALLBACK_HEIGHT=1080
FALLBACK_FPS=60
VNC_PASSWORD="sunshine"
VNC_PORT=5905
EXTRA_VM_KSCREEN=()
# shellcheck source=/dev/null
[ -f "$CONF" ] && source "$CONF"

VMOUT="Virtual-$VM_NAME"    # how KWin names it in kscreen-doctor

log() { echo "[$(date '+%F %T')] start: $*" >>"$LOG"; }

# strip ANSI color codes that kscreen-doctor -o emits, so parsing is reliable
kso() { kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }

# --- ensure we can reach the Wayland session / KWin ----------------------------
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

# --- resolution / fps requested by the Moonlight client ------------------------
W="${SUNSHINE_CLIENT_WIDTH:-$FALLBACK_WIDTH}"
H="${SUNSHINE_CLIENT_HEIGHT:-$FALLBACK_HEIGHT}"
FPS="${SUNSHINE_CLIENT_FPS:-$FALLBACK_FPS}"
FPS_MHZ=$(( FPS * 1000 ))            # kscreen custom modes want millihertz
log "client requested ${W}x${H}@${FPS} (DISABLE_PHYSICAL=$DISABLE_PHYSICAL)"

# --- record physical outputs that are enabled right now (for teardown) ---------
snap="$(kso)"
awk '/^Output:/{name=$3} /enabled/{print name}' <<<"$snap" | sort -u >"$STATE/enabled_before"
# record the true primary (the output flagged "priority 1") so we can restore it
awk '/^Output:/{name=$3} /priority 1$/{print name; exit}' <<<"$snap" >"$STATE/primary_before"
log "enabled before: $(tr '\n' ' ' <"$STATE/enabled_before")"
log "primary before: $(cat "$STATE/primary_before" 2>/dev/null)"

# clean up any stray virtual monitor from a previous crashed session
pkill -f "krfb-virtualmonitor.*$VM_NAME" 2>/dev/null && { log "swept stale krfb"; sleep 0.5; }

before="$(kso | awk '/^Output:/{print $3}' | sort)"

# --- launch the virtual monitor (detached; it must keep running) ---------------
setsid krfb-virtualmonitor \
  --resolution "${W}x${H}" \
  --name "$VM_NAME" \
  --password "$VNC_PASSWORD" \
  --port "$VNC_PORT" \
  >>"$LOG" 2>&1 &
VMPID=$!
echo "$VMPID" >"$STATE/vm.pid"
log "launched krfb-virtualmonitor pid=$VMPID (${W}x${H})"

# --- wait for the virtual output to appear -------------------------------------
NEWOUT=""
for _ in $(seq 1 40); do
  sleep 0.3
  now="$(kso | awk '/^Output:/{print $3}')"
  if grep -qx "$VMOUT" <<<"$now"; then
    NEWOUT="$VMOUT"; break
  fi
  # fallback: whatever output is new since we launched krfb
  cand="$(comm -13 <(echo "$before") <(echo "$now" | sort) | head -n1)"
  [ -n "$cand" ] && { NEWOUT="$cand"; break; }
done

if [ -z "$NEWOUT" ]; then
  log "ERROR: virtual output never appeared; NOT touching physical monitors (failsafe)"
  exit 0    # exit 0 so we never kill the stream, we just skip the display switch
fi
echo "$NEWOUT" >"$STATE/vm.output"
log "virtual output: $NEWOUT"

# --- pin it to the exact client mode -------------------------------------------
kscreen-doctor "output.$NEWOUT.addCustomMode.${W}.${H}.${FPS_MHZ}.full" >>"$LOG" 2>&1 \
  && log "added custom mode ${W}x${H}@${FPS}" || log "custom-mode add skipped (may already exist)"
if   kscreen-doctor "output.$NEWOUT.mode.${W}x${H}@${FPS}" >>"$LOG" 2>&1; then log "mode -> ${W}x${H}@${FPS}"
elif kscreen-doctor "output.$NEWOUT.mode.${W}x${H}"        >>"$LOG" 2>&1; then log "mode -> ${W}x${H} (default fps)"
else log "mode set failed; keeping compositor default"; fi

# --- apply any user extras (e.g. HiDPI scaling) --------------------------------
if [ "${#EXTRA_VM_KSCREEN[@]}" -gt 0 ]; then
  # substitute the literal token "VM" with the real output name
  extras=("${EXTRA_VM_KSCREEN[@]/VM/$NEWOUT}")
  kscreen-doctor "${extras[@]}" >>"$LOG" 2>&1 && log "applied extras: ${extras[*]}" \
    || log "WARN: extra kscreen args failed: ${extras[*]}"
fi

# --- make the virtual output active & primary ----------------------------------
kscreen-doctor "output.$NEWOUT.enable" "output.$NEWOUT.primary" >>"$LOG" 2>&1

# --- optionally turn the physical monitors off ---------------------------------
if [ "$DISABLE_PHYSICAL" = "true" ]; then
  disable_args=()
  while read -r name; do
    [ -z "$name" ] && continue
    [ "$name" = "$NEWOUT" ] && continue
    disable_args+=("output.$name.disable")
  done <"$STATE/enabled_before"

  if [ "${#disable_args[@]}" -gt 0 ]; then
    kscreen-doctor "${disable_args[@]}" >>"$LOG" 2>&1 \
      && log "disabled physical: ${disable_args[*]}" \
      || log "WARN: failed to disable some physical outputs"
  fi
else
  log "coexist mode: leaving physical monitors on"
fi

log "done"
exit 0
