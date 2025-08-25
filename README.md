# Network-Aware GNOME Lockscreen Color (RHEL 8/9)

Change the GNOME lock screen & desktop background **automatically** based on the active network on RHEL 8/9.  
Designed for **deterministic behavior** and **zero per-host user config**.

- Uses **NetworkManager dispatcher** events
- Auto-detects the active **local GNOME user** (no hardcoded username)
- Prefers **VPN** connections, otherwise the connection on the **default route** device
- Applies **solid-color swatches** via `picture-uri` (PNG) for reliability on RHEL GNOME
- Debounced + serialized to avoid “flip-flop” races

---

## How it works

1. A dispatcher script (`50-lockscreen-color`) runs on key NetworkManager events (`up`, `down`, `vpn-up`, `vpn-down`).
2. It finds the **active local graphical user** via `loginctl` (Wayland/X11 on `seat0`), requiring `gnome-shell` to be running.
3. It chooses the **authoritative connection**:
   - If a **VPN** connection is active → use that.
   - Else, the connection bound to the **default route** device.
   - Else, the first active connection.
4. It maps the connection name (e.g. `NET1`, `NET2`) to a **flat PNG swatch** and sets GNOME’s lockscreen + background **picture-URI** for that user.

> **Why PNG swatches instead of GNOME’s `primary-color`?**  
> On RHEL 8/9 GNOME, solid colors often “flash” then revert to gray unless a valid `picture-uri` is set.

---

## Repo contents

```
.
├─ dispatcher/50-lockscreen-color        # Main script (install to /etc/NetworkManager/dispatcher.d/)
├─ swatches/net1.png                     # #0e6625  (NET1)
├─ swatches/net2.png                     # #b20021  (NET2)
└─ README.md
```

> If you don’t want to commit PNGs, you can generate them with ImageMagick (see **Quick start**).

---

## Quick start

1) **Install swatches** (or provide your own):

```bash
sudo mkdir -p /usr/local/share/wallpapers
# If ImageMagick is available:
sudo convert -size 2560x1440 xc:"#0e6625" /usr/local/share/wallpapers/net1.png
sudo convert -size 2560x1440 xc:"#b20021" /usr/local/share/wallpapers/net2.png
sudo chmod 644 /usr/local/share/wallpapers/net*.png
```

2) **Install the dispatcher script**:

```bash
sudo install -m 0755 -o root -g root dispatcher/50-lockscreen-color /etc/NetworkManager/dispatcher.d/50-lockscreen-color
```

3) **Restart NetworkManager**:

```bash
sudo systemctl restart NetworkManager
```

4) **Test**:

```bash
# Bring up your connections by name (example names used by the script):
sudo nmcli connection up NET1
sudo nmcli connection up NET2

# View logs:
journalctl -t nm-lockscreen-color -b
```

---

## Default mapping

| Connection name | Color     | PNG path                               |
|-----------------|-----------|----------------------------------------|
| `NET1`          | `#0e6625` | `/usr/local/share/wallpapers/net1.png` |
| `NET2`          | `#b20021` | `/usr/local/share/wallpapers/net2.png` |

---

## 🔧 Customize for *your* network names

The script matches **NetworkManager connection names** (what you see in `nmcli`) and maps each one to a PNG swatch.

### 1) Find your exact connection names
```bash
nmcli connection show --active
# or all:
nmcli connection show
```
Use the **NAME** column exactly as shown (it’s case-sensitive and may include spaces).

### 2) Create swatches for each network (optional names/colors)
```bash
# Example: corp wired (blue) and home wifi (gold)
sudo convert -size 2560x1440 xc:"#0b61a4" /usr/local/share/wallpapers/corp.png
sudo convert -size 2560x1440 xc:"#c9a227" /usr/local/share/wallpapers/home.png
sudo chmod 644 /usr/local/share/wallpapers/*.png
```

### 3) Edit the mapping function in the script
Open `/etc/NetworkManager/dispatcher.d/50-lockscreen-color` and update **`pick_image_for_conn()`**:

```bash
pick_image_for_conn() {
  case "$1" in
    "Corp-Wired")                       echo "file:///usr/local/share/wallpapers/corp.png" ;;
    "Home Wi-Fi"|"HomeWifi"|"MySSID")   echo "file:///usr/local/share/wallpapers/home.png" ;;
    VPN-* )                             echo "file:///usr/local/share/wallpapers/net2.png" ;;  # wildcard: any name starting with "VPN-"
    NET1)                               echo "file:///usr/local/share/wallpapers/net1.png" ;;  # keep existing if desired
    NET2)                               echo "file:///usr/local/share/wallpapers/net2.png" ;;
    *)                                  echo "$IMG_FALLBACK" ;;  # fallback image
  esac
}
```

**Notes**
- This `case` uses **shell globbing**, not regex. Quotes are needed for names with spaces.
- You can combine multiple aliases with `|` as shown for “Home Wi-Fi”.
- Wildcards like `VPN-*` match prefixes; `*Guest*` would match substrings.
- You can point to any `file:///` URI, including bundled wallpapers.

### 4) Reload NetworkManager (or just change networks)
```bash
sudo systemctl restart NetworkManager
# or flip connections:
sudo nmcli connection up "Corp-Wired"
```

### 5) Optional: change the fallback
At the top of the script, set:
```bash
IMG_FALLBACK="file:///usr/local/share/wallpapers/safe-default.png"
```

---

## Script behavior details

- **User auto-detection**
  - Enumerates `loginctl list-sessions`; selects an **active**, **local**, **graphical** session (Type = `wayland`/`x11`, Remote = `no`), preferring **seat0**.
  - Requires `gnome-shell` to be running for the selected user.
  - Fallbacks: owner of a `gnome-shell` process; any user with a live `/run/user/<uid>/bus`.

- **Authoritative connection selection**
  1. Any active **VPN** connection (first match)
  2. Active connection on the **default route** device
  3. First active connection

- **Race resistance**
  - Reacts only to **decisive** statuses: `up`, `down`, `vpn-up`, `vpn-down`.
  - **Debounce**: waits 1s for routes to settle.
  - **Serialization**: lock file in `/run` avoids concurrent races.
  - **Idempotence**: state file in `/run` skips unnecessary re-applies.

- **Targets**
  - Sets both `org.gnome.desktop.screensaver.picture-uri` and `org.gnome.desktop.background.picture-uri` (plus `picture-uri-dark` when present).

---

## Requirements

- RHEL **8/9** with **GNOME** (Wayland or Xorg)
- NetworkManager (dispatcher enabled by default)
- `nmcli`, `loginctl`, `runuser`, `gsettings` available in PATH
- (Optional) ImageMagick `convert` to generate PNG swatches

---

## Troubleshooting

**See script logs**
```bash
journalctl -t nm-lockscreen-color -b
```

**Verify GUI session detection**
```bash
loginctl list-sessions
# Pick a SID and inspect:
loginctl show-session <SID> -p Type -p Active -p Remote -p Seat -p Name
# Confirm GNOME is running for the chosen user:
pgrep -u <user> -x gnome-shell
```

**Check the user’s DBus session**
```bash
UID=$(id -u <user>)
ls -l /run/user/$UID/bus   # should be a socket
```

**Manual gsettings sanity test**
```bash
U=<user>; UID=$(id -u "$U")
env XDG_RUNTIME_DIR=/run/user/$UID DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID/bus \
  runuser -u "$U" -- gsettings set org.gnome.desktop.screensaver picture-uri 'file:///usr/local/share/wallpapers/net1.png'
```

**Confirm active connections & default route**
```bash
nmcli connection show --active
ip route show default
```

**Script doesn’t run?**
```bash
# Permissions and ownership
ls -l /etc/NetworkManager/dispatcher.d/50-lockscreen-color
# -rwxr-xr-x root root

# Dispatcher service
systemctl status NetworkManager-dispatcher
# If disabled:
sudo systemctl enable --now NetworkManager-dispatcher
```

**SELinux**
```bash
# If you suspect denials:
sudo ausearch -m avc -ts recent
```

---

## Uninstall

```bash
sudo rm -f /etc/NetworkManager/dispatcher.d/50-lockscreen-color
sudo systemctl restart NetworkManager
# (Optional) remove swatches
sudo rm -f /usr/local/share/wallpapers/net1.png /usr/local/share/wallpapers/net2.png
# (Optional) clean state/lock files
sudo rm -f /run/nm-lockscreen-color.{last,lock}
```

---

## Compatibility & notes

- **Desktop**: GNOME (Classic or default). Other DEs may not honor the same keys.
- **Headless / SSH-only**: script skips changes if no local GNOME session is active.
- **Multi-user / fast user switching**: prefers the active session on `seat0`; see logs if you use multiple seats.

---

## Contributing

Issues and PRs welcome. If you add more mappings or DE support, include:
- RHEL version(s)
- GNOME version
- Steps to reproduce
- Logs (`journalctl -t nm-lockscreen-color -b`)

---

## License

MIT
