# Troubleshooting

## Cursor moves but clicks do nothing

### Symptom
You connect from Moonlight/Artemis, the mouse cursor moves on the streamed
screen, but **no mouse button does anything** — left, right, middle, from a real
mouse, a touchscreen, or the on-screen touchpad. Keyboard may or may not work.

### Root cause
Sunshine injects input by creating a **virtual uinput device**. On KDE Wayland,
KWin binds that device's capabilities (motion, buttons, scroll) when the device
appears. If Sunshine starts and creates the device *before KWin is fully up* —
which happens on autologin / fast-boot systems where the user service races the
compositor — KWin binds **motion but not buttons**. The result is a cursor that
moves but can't click.

We confirmed this with Sunshine's debug log (`min_log_level = 1`): the click
packets **do** arrive at the host —

```
--begin mouse button packet--
button [01]
--end mouse button packet--
```

— Sunshine writes them to its virtual mouse, but KWin never acts on them,
because the button capability was never bound. Restarting Sunshine *after* the
desktop is fully up re-creates the device correctly and clicks start working.

### Fix
Sunveil installs a **systemd user override** that makes Sunshine wait for
`kwin_wayland` to be running before it starts:

```
~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/sunveil.conf
```

```ini
[Service]
ExecStartPre=
ExecStartPre=/usr/bin/bash -lc 'for i in $(seq 1 60); do pgrep -x kwin_wayland >/dev/null && exit 0; sleep 0.5; done; exit 0'
```

If you ever hit the bug again (after a manual reconfigure, say), the immediate
cure is simply:

```bash
systemctl --user restart app-dev.lizardbyte.app.Sunshine.service
```

run once the desktop has fully loaded.

### Verify the fix survives a reboot
```bash
reboot
# after it comes back and you can stream, confirm the override is active:
systemctl --user cat app-dev.lizardbyte.app.Sunshine.service | grep -A2 sunveil
```

---

## Black stream / "no display" / Sunshine captures the wrong screen

Sunshine's default capture backend is **KMS**, which operates below the
compositor and **cannot see** a `krfb-virtualmonitor` output (those exist at the
KWin level). You must use the **KWin** capture backend and point it at the
virtual output by name.

Sunveil sets both automatically:

```ini
capture = kwin
output_name = Virtual-sunshine-vm
```

Confirm in `~/.config/sunshine/sunshine.conf`. Under `kwin` capture,
`output_name` is the **wayland output name string** (`Virtual-<VM_NAME>`), not a
numeric index like it is under KMS.

### Check what Sunshine is actually capturing
```bash
grep -E "Screencasting output name|Streaming display" ~/.config/sunshine/sunshine.log | tail
```
You want to see `Virtual-sunshine-vm`. If you see `DP-1`/`HDMI-A-1`/etc., the
`output_name` didn't take — re-run `./install.sh`.

---

## Nothing happens at all when I connect

Watch the hook log live:

```bash
tail -f ~/.config/sunshine/hooks/hook.log
```

Then connect. A healthy start looks like:

```
start: client requested 2560x1440@144 (DISABLE_PHYSICAL=true)
start: enabled before: DP-1 DP-2 DP-3
start: primary before: DP-3
start: launched krfb-virtualmonitor pid=NNNN (2560x1440)
start: virtual output: Virtual-sunshine-vm
start: added custom mode 2560x1440@144
start: mode -> 2560x1440@144
start: disabled physical: output.DP-1.disable output.DP-2.disable output.DP-3.disable
start: done
```

Failure modes:

| Log line | Meaning | Fix |
|---|---|---|
| `virtual output never appeared` | `krfb-virtualmonitor` didn't create a display | Ensure `krfb` is installed and `$XDG_SESSION_TYPE` is `wayland` |
| no lines at all | prep command not wired | Re-run `./install.sh`; check `global_prep_cmd` in `sunshine.conf` |
| `mode set failed` | client asked for a mode KWin rejected | Non-fatal; stream continues at the compositor default |

---

## `krfb-virtualmonitor: Failed to register with host portal`

```
Failed to register with host portal QDBusError(... "Could not register app ID:
App info not found for 'org.kde.krfb-virtualmonitor'")
```

**Harmless.** A cosmetic desktop-portal app-id warning. The virtual monitor is
created and works regardless. Ignore it.

---

## Physical monitors didn't come back after a stream

The `stream-end.sh` hook restores them, but if Sunshine crashed mid-stream it
may not have run. Recover manually (adjust connector names from `kscreen-doctor -o`):

```bash
kscreen-doctor output.DP-1.enable output.DP-2.enable output.DP-3.enable
kscreen-doctor output.DP-3.primary
pkill -f 'krfb-virtualmonitor.*sunshine-vm'
```

The hook records your pre-stream state in
`~/.config/sunshine/hooks/state/enabled_before` and `primary_before` — so even a
manual re-run of `stream-end.sh` will restore correctly.

---

## AV1 / encoder errors in the log

```
[av1_nvenc] Provided device doesn't support required NVENC features
Could not open codec [av1_nvenc]
```

Harmless if your GPU simply lacks AV1 encode (e.g. RTX 30-series). Sunshine falls
back to H.264/HEVC. The log even says *"Ignore any errors mentioned above."*

---

## Getting more detail

Enable Sunshine debug logging temporarily:

```bash
echo 'min_log_level = 1' >> ~/.config/sunshine/sunshine.conf
systemctl --user restart app-dev.lizardbyte.app.Sunshine.service
# reproduce, read ~/.config/sunshine/sunshine.log, then remove the line again
```
