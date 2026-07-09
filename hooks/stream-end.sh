#!/usr/bin/env bash
# Sunveil — Sunshine stream-end hook.
#
# Restores the physical monitors and tears down the virtual monitor created by
# stream-start.sh. Safe to run even if start failed partway (it only acts on
# recorded state).

set -uo pipefail

HOOKDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HOOKDIR/hook.log"
STATE="$HOOKDIR/state"
CONF="$HOOKDIR/sunveil.conf"

VM_NAME="sunshine-vm"
# shellcheck source=/dev/null
[ -f "$CONF" ] && source "$CONF"

log() { echo "[$(date '+%F %T')] end:   $*" >>"$LOG"; }

export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

# --- re-enable every output that was on before the stream ----------------------
if [ -f "$STATE/enabled_before" ]; then
  enable_args=()
  while read -r name; do
    [ -z "$name" ] && continue
    enable_args+=("output.$name.enable")
  done <"$STATE/enabled_before"
  if [ "${#enable_args[@]}" -gt 0 ]; then
    kscreen-doctor "${enable_args[@]}" >>"$LOG" 2>&1 \
      && log "re-enabled: ${enable_args[*]}" \
      || log "WARN: failed to re-enable some outputs"
  fi
else
  log "WARN: no enabled_before state; leaving displays as-is"
fi

# --- kill the virtual monitor --------------------------------------------------
if [ -f "$STATE/vm.pid" ]; then
  VMPID="$(cat "$STATE/vm.pid")"
  if kill "$VMPID" 2>/dev/null; then
    log "killed krfb-virtualmonitor pid=$VMPID"
  else
    pkill -f "krfb-virtualmonitor.*$VM_NAME" 2>/dev/null && log "swept stray krfb (pid $VMPID gone)"
  fi
  rm -f "$STATE/vm.pid"
else
  pkill -f "krfb-virtualmonitor.*$VM_NAME" 2>/dev/null && log "swept krfb (no pidfile)"
fi

# --- restore the true primary that was set before the stream -------------------
PRIMARY=""
[ -f "$STATE/primary_before" ] && PRIMARY="$(cat "$STATE/primary_before")"
# fallback: first previously-enabled output if primary wasn't recorded
[ -z "$PRIMARY" ] && [ -f "$STATE/enabled_before" ] && PRIMARY="$(head -n1 "$STATE/enabled_before")"
if [ -n "$PRIMARY" ]; then
  kscreen-doctor "output.$PRIMARY.primary" >>"$LOG" 2>&1 \
    && log "restored primary to $PRIMARY" \
    || log "WARN: failed to restore primary $PRIMARY"
fi

log "done"
exit 0
