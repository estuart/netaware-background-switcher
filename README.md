# Network-Aware GNOME Backgrounds (RHEL 8/9)

Automatically set the GNOME lock screen and desktop background based on the active network, and brand the GDM login screen (banner + small badge) to match.

- **Network-aware** via NetworkManager dispatcher
- **User auto-detection** (no hardcoded usernames)
- **Deterministic active connection** selection (VPN > default-route device > first active)
- **Solid PNG swatches** for reliability on RHEL GNOME
- **Greeter branding** via system dconf (optional, installed by default)

---

## What gets installed

The installer configures both per-user and login (GDM) branding:

- **User session (per-user):**
  - `/etc/NetworkManager/dispatcher.d/50-lockscreen-color`
  - Sets `org.gnome.desktop.screensaver.picture-uri` and `org.gnome.desktop.background.picture-uri` to a color swatch PNG per active connection
- **GDM (login screen):**
  - `/usr/local/sbin/gdm-login-bg-switcher` (oneshot switcher)
  - `/etc/systemd/system/gdm-login-bg.service` (runs after network-online)
  - `/etc/NetworkManager/dispatcher.d/60-gdm-login-bg` (updates greeter on decisive network changes)
  - `/etc/dconf/db/gdm.d/90-gdm-login-branding` (written by the switcher)
- **Assets:**
  - Swatches: `/usr/local/share/wallpapers/*.png` (2560x1440)
  - Badges: `/usr/local/share/wallpapers/badges/*_logo.png` (128x128)

> The installer can generate swatches/badges for you using ImageMagick, or you can provide your own PNGs.

---

## Requirements

- RHEL 8/9 with GNOME (Wayland or Xorg)
- NetworkManager (dispatcher enabled)
- Tools: `nmcli`, `loginctl`, `runuser`, `gsettings`, `flock`, `systemctl`, `ip`, `awk`, `sed`, `tr`, `dconf`, `logger`, `ps`, `pgrep`, `id`
- If generating swatches: ImageMagick `convert`

---

## Quick start (interactive)

```bash
# From repo root
sudo bash install-nm-lockscreen-colors.sh
# Follow prompts to pick a color for each discovered NetworkManager connection
```

- After install:
  - `sudo nmcli connection up "<Your Connection>"`
  - `journalctl -t nm-lockscreen-color -b`
  - Log out to GDM or reboot to see the greeter branding, or change networks at the greeter.

---

## Non-interactive install (for scripting)

Use `--map` to define connection-to-color mappings and `--fallback` to set a default color when no mapping matches. The installer will generate swatches/badges and skip prompts.

```bash
sudo bash install-nm-lockscreen-colors.sh \
  --map "Corp-Wired=#0b61a4" \
  --map "Home Wi-Fi=#c9a227" \
  --fallback #808080
```

Notes:
- `--map` is repeatable; the connection `NAME` must match exactly as in `nmcli`.
- Colors must be hex `#RRGGBB`.
- Connections without a `--map` entry are skipped.

---

## Use pre-supplied PNG swatches (no ImageMagick)

If ImageMagick isn’t available, or you prefer to ship your own PNGs, use `--use-swatches`. Filenames must be the sanitized connection names (lowercase; spaces/punctuation to `_`), e.g. `corp-wired.png`. Optionally include a badge as `<name>_logo.png`.

```bash
# Interactive, using PNGs from ./swatches
sudo bash install-nm-lockscreen-colors.sh --use-swatches --swatches-dir ./swatches

# Non-interactive with maps, but still prefer provided PNGs where present
sudo bash install-nm-lockscreen-colors.sh --use-swatches --swatches-dir ./swatches \
  --map "Corp-Wired=#0b61a4" --map "Home Wi-Fi=#c9a227"
```

- If `--swatches-dir` is omitted, the installer uses `./swatches` if present, otherwise `/usr/local/share/wallpapers`.
- When `--use-swatches` is set, swatches are copied from the directory instead of generated. If a PNG for a connection is missing, that connection is skipped (you can still provide a color to generate if ImageMagick is installed).

---

## Usage

```bash
sudo bash install-nm-lockscreen-colors.sh                                  # interactive install
sudo bash install-nm-lockscreen-colors.sh --map "NAME=#RRGGBB" [--map ...] [--fallback #RRGGBB]
sudo bash install-nm-lockscreen-colors.sh --use-swatches [--swatches-dir PATH]  # use provided PNGs
sudo bash install-nm-lockscreen-colors.sh --uninstall                      # uninstall
sudo bash install-nm-lockscreen-colors.sh --uninstall --purge              # uninstall + remove generated swatches/badges
sudo bash install-nm-lockscreen-colors.sh --help                           # help
```

- **--uninstall** removes: dispatcher, GDM switcher, GDM NM hook, systemd unit, dconf snippet, and cleans state/lock files.
- **--purge** additionally removes generated swatches/badges under `/usr/local/share/wallpapers`.

---

## How it works

1. A dispatcher script (`50-lockscreen-color`) runs on NetworkManager events (`up`, `down`, `vpn-up`, `vpn-down`).
2. It locates the active local graphical user (Wayland/X11 on seat0) with `loginctl` and confirms `gnome-shell` is running.
3. It picks the authoritative connection:
   - An active VPN connection, otherwise
   - The connection bound to the default route device, otherwise
   - The first active connection
4. It maps the connection name to a PNG swatch (`file://` URI) and applies GNOME settings for that user.
5. A separate GDM oneshot switcher writes the greeter background, banner text, and an optional small badge logo to the system dconf database and restarts GDM only if no user sessions are active.

---

## Customize

- The installer builds mapping tables from your chosen colors at install time and writes them directly into:
  - `/etc/NetworkManager/dispatcher.d/50-lockscreen-color`
  - `/usr/local/sbin/gdm-login-bg-switcher`
- To change mappings later:
  - Edit those files’ mapping functions and run `sudo systemctl restart NetworkManager`.
  - For GDM changes, either reboot, log out to the greeter, or run `sudo /usr/local/sbin/gdm-login-bg-switcher`.
- Swatches and badges can be replaced with any PNGs at the same paths; keep permissions world-readable.

---

## Troubleshooting

- **User-session logging**
  ```bash
  journalctl -t nm-lockscreen-color -b
  ```
- **GDM switcher logging**
  ```bash
  journalctl -t gdm-login-bg -b
  ```
- **Verify GUI session detection**
  ```bash
  loginctl list-sessions
  loginctl show-session <SID> -p Type -p Active -p Remote -p Seat -p Name
  pgrep -u <user> -x gnome-shell
  ```
- **Active connections & default route**
  ```bash
  nmcli connection show --active
  ip route show default
  ```
- **Dispatcher service**
  ```bash
  systemctl status NetworkManager-dispatcher
  sudo systemctl enable --now NetworkManager-dispatcher
  ```
- **SELinux**
  ```bash
  sudo ausearch -m avc -ts recent
  ```

---

## Repo contents

```
.
├─ install-nm-lockscreen-colors.sh           # Installer (install/uninstall)
├─ swatches/                                 # Optional PNGs for --use-swatches
└─ README.md
```

---

## Uninstall

```bash
sudo bash install-nm-lockscreen-colors.sh --uninstall
# Or also remove generated images:
sudo bash install-nm-lockscreen-colors.sh --uninstall --purge
```

This stops and removes the unit/hook/switcher, cleans state/locks, and deletes the dconf snippet. Purge also removes generated swatches/badges.

---

## Contributing

Issues and PRs welcome. If you add mappings or DE support, include:
- RHEL version(s) and GNOME version
- Steps to reproduce
- Logs (`journalctl -t nm-lockscreen-color -b`, `journalctl -t gdm-login-bg -b`)

---

## License

MIT
