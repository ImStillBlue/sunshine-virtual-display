# 🌒 Sunveil

**On-demand headless virtual display for [Sunshine](https://github.com/LizardByte/Sunshine) on CachyOS (KDE Plasma 6 / Wayland / NVIDIA).**

Stream your PC with [Moonlight](https://moonlight-stream.org/) / Artemis at your
**client's native resolution** — phone, tablet, laptop, TV — with the host's
physical monitors **turned off** for the duration of the stream, then restored
automatically when you disconnect.

No dummy HDMI plug. No always-on fake display. No Windows. Pure software, built
for and tested on CachyOS + Plasma 6 Wayland + NVIDIA proprietary drivers.

---

## What it does

When a Moonlight client connects, Sunveil:

1. **Creates a virtual monitor** at the *client's* exact resolution and refresh
   rate (e.g. your phone gets 1080×2340@90, your laptop gets 2560×1440@144).
2. **Turns off your physical monitors** so the stream is an exclusive, private
   headless display (optional — see *Coexist mode*).
3. Points Sunshine's KWin capture at the virtual display and streams it.
4. On disconnect, **restores everything** — physical monitors back on, virtual
   display destroyed, primary monitor and layout exactly as they were.

It's driven entirely by Sunshine's `global_prep_cmd` hooks, so there's nothing
running when you're not streaming.

### Why not just use a dummy plug or Apollo?

- **Dummy HDMI plugs** work but are a fixed resolution, always present, and cost
  money/ports. Sunveil is dynamic and leaves no trace when idle.
- **Apollo's** virtual display is **Windows-only** (it relies on SudoVDA). On
  Linux it can't create a virtual display. Sunveil fills that gap for CachyOS.
- **Hermes** (an Apollo-for-Linux fork) is a great heavier alternative if you
  want a purpose-built host; Sunveil instead enhances the Sunshine you already
  run, in ~15 minutes, with stock packages.

---

## Requirements

| | |
|---|---|
| **OS** | CachyOS / Arch (uses `pacman`) |
| **Desktop** | KDE Plasma 6 on **Wayland** |
| **GPU** | Any Sunshine-supported GPU. Developed on NVIDIA (proprietary/open). |
| **Sunshine** | Already installed and working (`systemctl --user status app-dev.lizardbyte.app.Sunshine.service`) |
| **Packages** | `krfb`, `kscreen` — the installer adds these for you |

> **X11 is not supported.** The virtual display is created at the KWin/Wayland
> compositor level. If `echo $XDG_SESSION_TYPE` prints `x11`, log into a
> "Plasma (Wayland)" session first.

---

## Install

```bash
git clone https://github.com/ImStillBlue/sunveil.git
cd sunveil
./install.sh
```

That's it. The installer is **idempotent** and **safe on an existing Sunshine
setup** — it backs up your `sunshine.conf`, merges only the keys it needs
(preserving any prep commands you already have), installs the hooks, and adds a
systemd fix for the boot-time click bug (see *Troubleshooting*).

Then just **connect from Moonlight** and start streaming.

### Options

```bash
./install.sh --coexist      # keep physical monitors ON (extend, not replace)
./install.sh --no-restart   # don't restart Sunshine at the end
./install.sh --yes          # non-interactive
```

### Uninstall

```bash
./uninstall.sh
```

Restores your Sunshine config from the backup and removes everything Sunveil
added. (Leaves the `krfb` package and any autologin you set up — those are
yours to keep or remove.)

---

## Modes

Set in `~/.config/sunshine/hooks/sunveil.conf` (or via `--coexist` at install):

| `DISABLE_PHYSICAL` | Behaviour |
|---|---|
| `true` *(default)* | **Headless** — physical monitors off while streaming, restored on disconnect. |
| `false` | **Coexist** — virtual display is an *extra* screen; your real monitors keep showing your desktop. Great for streaming to a second device while someone uses the PC. |

Changes take effect on the next stream — no restart needed.

---

## Truly headless: stream a PC that was never logged in

Sunshine runs as a **user** service, so it only starts after you log into a
Plasma session. To stream a freshly-booted machine (e.g. a headless box in a
closet), enable **autologin** so Plasma comes up on boot:

```bash
# Plasma 6 uses SDDM ("plasmalogin"). Create an autologin drop-in:
printf '[Autologin]\nUser=%s\nSession=plasma.desktop\nRelogin=false\n' "$USER" \
  | sudo tee /etc/sddm.conf.d/autologin.conf
```

- `Relogin=false` — autologin only at boot; you can still log out normally.
- `Relogin=true` — re-login even after logout/crash (pure appliance mode).

> **Note:** `loginctl enable-linger` does **not** help here — linger starts user
> *daemons* at boot but never starts a graphical Plasma session, which Sunshine
> needs to capture. Autologin is the right tool.

See [`docs/AUTOLOGIN.md`](docs/AUTOLOGIN.md) for the security tradeoffs and a
KWallet note.

---

## Troubleshooting

### 🖱️ Cursor moves but clicks do nothing

The single most common issue on autologin/fast-boot systems. Sunshine created
its virtual input device *before* KWin finished starting, so pointer **motion**
bound but **button** capabilities didn't.

**Sunveil installs a systemd override that fixes this** by making Sunshine wait
for KWin before it starts. If you still hit it (e.g. after a manual change):

```bash
systemctl --user restart app-dev.lizardbyte.app.Sunshine.service
```

…once the desktop is fully up. See [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)
for the full explanation and how we diagnosed it.

### The stream is black / Sunshine can't find the display

Sunshine's default capture (`kms`) **cannot see** compositor-level virtual
monitors. Sunveil sets `capture = kwin` for you. Confirm it's set:

```bash
grep -E 'capture|output_name' ~/.config/sunshine/hooks/../sunshine.conf
# capture = kwin
# output_name = Virtual-sunshine-vm
```

### Nothing happens when I connect

Watch the hook log live while you connect:

```bash
tail -f ~/.config/sunshine/hooks/hook.log
```

You should see `client requested WxH@fps`, `virtual output: Virtual-sunshine-vm`,
and (in headless mode) `disabled physical: …`. If it says
`virtual output never appeared`, `krfb-virtualmonitor` failed — check that
`krfb` is installed and you're on Wayland.

### `krfb-virtualmonitor: Failed to register with host portal`

**Harmless.** It's a cosmetic app-id warning from krfb; the virtual monitor
still works. Ignore it.

More in [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

---

## How it works (for the curious)

```
Moonlight client connects
        │
        ▼
Sunshine runs global_prep_cmd "do"  ──►  hooks/stream-start.sh
        │                                   • reads SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS
        │                                   • krfb-virtualmonitor --resolution WxH
        │                                   • kscreen-doctor: add custom mode, set it
        │                                   • kscreen-doctor: disable physical outputs
        ▼
Sunshine captures output_name = Virtual-sunshine-vm  (capture = kwin)
        │
        ▼
… you stream …
        │
Moonlight disconnects
        ▼
Sunshine runs global_prep_cmd "undo"  ──►  hooks/stream-end.sh
                                            • re-enable physical outputs
                                            • restore original primary
                                            • kill krfb-virtualmonitor
```

Files installed:

```
~/.config/sunshine/hooks/stream-start.sh     # the "do" hook
~/.config/sunshine/hooks/stream-end.sh       # the "undo" hook
~/.config/sunshine/hooks/sunveil.conf        # your tunables
~/.config/sunshine/hooks/hook.log            # per-stream debug log
~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/sunveil.conf
~/.config/sunshine/sunshine.conf             # merged: capture, output_name, global_prep_cmd
                                             # (original saved as sunshine.conf.sunveil-bak.*)
```

---

## Credits & license

Built on the shoulders of [Sunshine](https://github.com/LizardByte/Sunshine),
KDE's `krfb-virtualmonitor`, and `kscreen-doctor`. The virtual-monitor approach
was inspired by community write-ups on running Sunshine headless on Plasma 6
Wayland.

MIT — see [LICENSE](LICENSE).

Contributions welcome, especially test reports from other CachyOS/Arch + Plasma
6 configurations. See [CONTRIBUTING.md](CONTRIBUTING.md).
