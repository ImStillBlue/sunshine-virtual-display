# Contributing to Sunveil

Thanks for helping! This project is small and focused: making Sunshine run a
dynamic headless virtual display on CachyOS / Arch + KDE Plasma 6 Wayland.

## Most valuable contribution: test reports

Sunveil is validated on a specific stack (Plasma 6.7, NVIDIA, CachyOS). If you
run something different, a quick report helps a lot. Please open an issue with:

- CachyOS / Arch, and `plasmashell --version`
- `echo $XDG_SESSION_TYPE` (must be `wayland`)
- GPU + driver (`nvidia-smi` or `lspci -k | grep -A2 VGA`)
- Sunshine version (`sunshine --version` or the package)
- What worked / what didn't, plus the relevant slice of
  `~/.config/sunshine/hooks/hook.log`

## Code changes

- **Shell:** `bash`, `set -uo pipefail`, keep it POSIX-friendly where practical.
  Run `bash -n` and, if you have it, `shellcheck` before submitting.
- **Don't break idempotency.** `install.sh` must be safe to run repeatedly and
  must never clobber a user's existing Sunshine config — it backs up and merges.
- **Don't break the failsafe.** `stream-start.sh` must never leave the user
  headless if the virtual monitor fails to appear (it exits 0 without disabling
  physical outputs in that case).
- Test the config merge against: empty config, config with unrelated keys, and a
  config that already has a foreign `global_prep_cmd` entry (must be preserved).

## Scope

In scope: reliability on the target stack, more Plasma/GPU coverage, better
diagnostics, quality-of-life install options.

Probably out of scope: non-KDE compositors (GNOME/wlroots use different virtual
display mechanisms), non-Arch distros (different package managers). Forks
welcome for those.
