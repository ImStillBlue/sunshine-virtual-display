# Autologin — streaming a headless / freshly-booted PC

Sunshine runs as a **user** systemd service. It can only capture a desktop that
exists, and a Plasma Wayland session only exists **after login**. So on a fresh
boot sitting at the SDDM ("plasmalogin") login screen, Sunshine either isn't
running or has nothing to capture, and Moonlight won't see the host.

To stream a machine nobody is physically logging into, make Plasma start on
boot via **autologin**.

## Why not `loginctl enable-linger`?

Because linger starts your **user services** at boot — it does **not** start a
graphical session. Sunshine would launch and immediately have no compositor to
capture. Linger solves headless *daemons*, not headless *desktops*. Autologin is
the correct tool.

## Enable autologin (SDDM / Plasma 6)

```bash
printf '[Autologin]\nUser=%s\nSession=plasma.desktop\nRelogin=false\n' "$USER" \
  | sudo tee /etc/sddm.conf.d/autologin.conf
```

`plasmalogin` reads `/etc/sddm.conf.d/` at higher priority than its defaults, so
this drop-in wins. Reboot and the box comes up already in your Plasma Wayland
session, KWin starts, the Sunshine user service starts, and Moonlight can reach
it.

### `Relogin` — pick per use case
- `Relogin=false` — autologin **only at boot**. You can still log out to the
  greeter and switch users. Best for a machine that's also a daily driver.
- `Relogin=true` — re-login immediately even after a logout or session crash.
  Maximum resilience for a pure streaming appliance; you can never reach the
  login screen.

## Things to know

1. **Security.** Autologin means anyone who powers on the PC lands in your
   unlocked desktop. Fine for a box behind your own door; think twice on a
   laptop or shared space.

2. **KWallet prompt.** If your KDE Wallet has a *separate* password (not
   auto-unlocked by login), you may get a one-time wallet prompt after
   autologin. Sunshine doesn't need the wallet, so streaming still works — it's
   cosmetic. To silence it: *System Settings → KDE Wallet* → set the wallet's
   password to blank, or match it to your login password so it auto-unlocks.

3. **Monitors on at idle.** After autologin the desktop shows on your physical
   monitors as normal; they only go dark once a client connects (Sunveil's
   hook). If you want them off *while idle waiting for a connection* too, that's
   a separate tweak — open an issue and we can add an idle mode.

## Undo

```bash
sudo rm /etc/sddm.conf.d/autologin.conf
```
