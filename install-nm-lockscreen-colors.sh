#!/bin/bash
# install-nm-lockscreen-colors.sh
#
# Interactive installer for network-aware GNOME backgrounds on RHEL 8/9:
#  - Per-user session: changes lock screen + desktop via NetworkManager dispatcher
#  - GDM greeter (login screen): banner + small badge logo, safe (won't cover form)
#
# Usage:
#   sudo bash install-nm-lockscreen-colors.sh                # interactive install
#   sudo bash install-nm-lockscreen-colors.sh --map "NAME=#RRGGBB" [--map ...] [--fallback #RRGGBB]  # non-interactive
#   sudo bash install-nm-lockscreen-colors.sh --use-swatches [--swatches-dir PATH]                  # use provided PNGs
#   sudo bash install-nm-lockscreen-colors.sh --uninstall    # uninstall
#   sudo bash install-nm-lockscreen-colors.sh --uninstall --purge  # uninstall and remove generated swatches/badges
#   sudo bash install-nm-lockscreen-colors.sh --help         # help
#
# After install:
#   sudo nmcli connection up "<Your Connection>"
#   journalctl -t nm-lockscreen-color -b
#
# To preview greeter changes: log out to the login screen or reboot.
# (GDM reads its settings at start; the unit runs after networking is online.)

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

# -------- Paths / constants --------
WALLPAPER_DIR="/usr/local/share/wallpapers"
BADGE_DIR="$WALLPAPER_DIR/badges"

# User-session dispatcher (lockscreen/desktop)
DISPATCHER_PATH="/etc/NetworkManager/dispatcher.d/50-lockscreen-color"

# GDM greeter switcher + unit + NM hook
GREETER_SWITCHER="/usr/local/sbin/gdm-login-bg-switcher"
GREETER_UNIT="/etc/systemd/system/gdm-login-bg.service"
GDM_NM_HOOK="/etc/NetworkManager/dispatcher.d/60-gdm-login-bg"

# GDM dconf profile/DB
DCONF_PROFILE="/etc/dconf/profile/gdm"
DCONF_SNIPPET="/etc/dconf/db/gdm.d/90-gdm-login-branding"

print_usage() {
  cat <<'USAGE'
install-nm-lockscreen-colors.sh

Interactive or non-interactive installer for network-aware GNOME lockscreen/desktop + GDM greeter branding.

Usage:
  sudo bash install-nm-lockscreen-colors.sh                                  # interactive install
  sudo bash install-nm-lockscreen-colors.sh --map "NAME=#RRGGBB" [--map ...] [--fallback #RRGGBB]
  sudo bash install-nm-lockscreen-colors.sh --use-swatches [--swatches-dir PATH]  # use provided PNGs
  sudo bash install-nm-lockscreen-colors.sh --uninstall                      # uninstall
  sudo bash install-nm-lockscreen-colors.sh --uninstall --purge              # uninstall + purge images
  sudo bash install-nm-lockscreen-colors.sh --help                           # help

Flags:
  --map "NAME=#RRGGBB"   Map a NetworkManager connection NAME to a color (repeatable)
  --fallback #RRGGBB     Fallback color when no mapping matches (non-interactive)
  --use-swatches         Read PNGs from swatches dir instead of generating with ImageMagick
  --swatches-dir PATH    Directory to read PNGs from (default: ./swatches in repo or /usr/local/share/wallpapers)
  --uninstall, -u        Remove installed files (dispatcher, greeter switcher, unit, NM hook, dconf snippet)
  --purge, -p            With --uninstall, also delete generated swatches/badges under /usr/local/share/wallpapers
  --help, -h             Show this help

Examples:
  sudo bash dispatcher/install-nm-lockscreen-colors.sh \
    --map "Corp-Wired=#0b61a4" --map "Home Wi-Fi=#c9a227" --fallback #808080
  sudo bash dispatcher/install-nm-lockscreen-colors.sh --use-swatches --swatches-dir ./swatches
USAGE
}

uninstall_everything() {
  local purge_flag="${1:-false}"
  echo "Uninstalling Network-Aware GNOME background + GDM greeter components..."

  systemctl disable --now gdm-login-bg.service 2>/dev/null || true
  rm -f "$GREETER_UNIT"
  rm -f "$GREETER_SWITCHER" || true
  rm -f "$GDM_NM_HOOK" || true
  rm -f "$DISPATCHER_PATH" || true

  if [ -f "$DCONF_SNIPPET" ]; then
    rm -f "$DCONF_SNIPPET" || true
    dconf update 2>/dev/null || true
  fi

  rm -f /run/nm-lockscreen-color.lock /run/nm-lockscreen-color.last 2>/dev/null || true

  if [ "$purge_flag" = "true" ]; then
    echo "Purging generated swatches and badges under $WALLPAPER_DIR ..."
    rm -f "$BADGE_DIR"/*.png 2>/dev/null || true
    rm -f "$WALLPAPER_DIR"/*.png 2>/dev/null || true
    rmdir "$BADGE_DIR" 2>/dev/null || true
    rmdir "$WALLPAPER_DIR" 2>/dev/null || true
  fi

  systemctl restart NetworkManager 2>/dev/null || true
  echo "Uninstall complete."
}

# -------- Helpers / prereqs --------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

# -------- Argument parsing --------
MODE="install"
PURGE="false"
USE_SWATCHES="false"
SWATCHES_DIR=""
# Non-interactive maps
declare -A CLI_MAPS
CLI_MAPS_COUNT=0
CLI_FALLBACK=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      print_usage; exit 0 ;;
    -u|--uninstall|uninstall)
      MODE="uninstall"; shift; continue ;;
    -p|--purge)
      PURGE="true"; shift; continue ;;
    --install|install)
      MODE="install"; shift; continue ;;
    --use-swatches)
      USE_SWATCHES="true"; shift; continue ;;
    --swatches-dir)
      shift
      [ "${1:-}" ] || { echo "--swatches-dir requires a path" >&2; exit 1; }
      SWATCHES_DIR="$1"; shift; continue ;;
    --map)
      shift
      [ "${1:-}" ] || { echo "--map requires \"NAME=#RRGGBB\"" >&2; exit 1; }
      kv="$1"
      name="${kv%%=*}"; color="${kv#*=}"
      if [ -z "$name" ] || [ "$name" = "$color" ]; then
        echo "Invalid --map format. Use --map \"NAME=#RRGGBB\"" >&2; exit 1
      fi
      CLI_MAPS["$name"]="$color"
      CLI_MAPS_COUNT=$((CLI_MAPS_COUNT+1))
      shift; continue ;;
    --fallback)
      shift
      [ "${1:-}" ] || { echo "--fallback requires a color like #RRGGBB" >&2; exit 1; }
      CLI_FALLBACK="$1"; shift; continue ;;
    *)
      echo "Unknown argument: $1" >&2
      print_usage
      exit 1
      ;;
  esac
done

if [ "$MODE" = "uninstall" ]; then
  uninstall_everything "$PURGE"
  exit 0
fi

need_cmd nmcli
need_cmd loginctl
need_cmd runuser
need_cmd gsettings
if [ "$USE_SWATCHES" != "true" ]; then
  need_cmd convert     # ImageMagick
fi
need_cmd flock
need_cmd systemctl
need_cmd ip
need_cmd awk
need_cmd sed
need_cmd tr
need_cmd dconf
need_cmd logger
need_cmd ps
need_cmd pgrep
need_cmd id

mkdir -p "$WALLPAPER_DIR" "$BADGE_DIR"
chmod 755 "$WALLPAPER_DIR" "$BADGE_DIR"

# Resolve swatches source dir
if [ "$USE_SWATCHES" = "true" ]; then
  if [ -z "$SWATCHES_DIR" ]; then
    if [ -d "./swatches" ]; then
      SWATCHES_DIR="./swatches"
    else
      SWATCHES_DIR="$WALLPAPER_DIR"
    fi
  fi
fi

# -------- Discover connections --------
mapfile -t CONNECTIONS < <(nmcli -t -f NAME connection show | awk -F: '{print $1}' | sed '/^$/d' | sort -u)
if [ "${#CONNECTIONS[@]}" -eq 0 ]; then
  echo "No NetworkManager connections found. Create at least one and re-run." >&2
  exit 1
fi

echo "Discovered NetworkManager connections:"
for n in "${CONNECTIONS[@]}"; do echo "  - $n"; done
echo

sanitize_filename() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'A-Za-z0-9._-' '_' | sed 's/_\{2,\}/_/g; s/^_//; s/_$//'
}
is_hex() { [[ "$1" =~ ^#[A-Fa-f0-9]{6}$ ]]; }

default_color_for() {
  case "$1" in
    NET1) echo "#b20021" ;;
    NET2) echo "#0e6625" ;;
    *)    echo "#808080" ;;
  esac
}

# -------- Build mappings (non-interactive or interactive) --------
declare -A MAP_NAME_TO_URI
declare -A MAP_NAME_TO_BG
declare -A MAP_NAME_TO_LOGO
FALLBACK_URI=""
FALLBACK_BG_PATH=""
LOGO_FALLBACK=""

noninteractive="false"
map_count=${CLI_MAPS_COUNT:-0}
fallback_val="${CLI_FALLBACK:-}"
if [ "$map_count" -gt 0 ] || [ -n "$fallback_val" ]; then
  noninteractive="true"
fi

if [ "$noninteractive" = "true" ]; then
  echo "Running non-interactive install..."
  for NAME in "${CONNECTIONS[@]}"; do
    COLOR=""
    if declare -p CLI_MAPS >/dev/null 2>&1 && [[ -v CLI_MAPS[$NAME] ]]; then
      COLOR="${CLI_MAPS[$NAME]}"
    fi
    if [ -z "$COLOR" ] && [ "$USE_SWATCHES" != "true" ]; then
      echo "  -> No color provided for \"$NAME\"; skipping"
      continue
    fi

    FN="$(sanitize_filename "$NAME")"
    SWATCH_PATH="$WALLPAPER_DIR/$FN.png"
    BADGE_PATH="$BADGE_DIR/${FN}_logo.png"

    if [ -n "$COLOR" ] && [ "$USE_SWATCHES" != "true" ]; then
      echo "  -> Generating swatch $SWATCH_PATH with color $COLOR"
      convert -size 2560x1440 "xc:${COLOR}" "$SWATCH_PATH"
      chmod 644 "$SWATCH_PATH"

      echo "  -> Generating badge  $BADGE_PATH with color $COLOR"
      convert -size 128x128 "xc:${COLOR}" "$BADGE_PATH"
      chmod 644 "$BADGE_PATH"
    else
      # Use provided swatch from source dir
      SRC="$SWATCHES_DIR/$FN.png"
      if [ ! -r "$SRC" ]; then
        echo "  -> No PNG found for \"$NAME\" in $SWATCHES_DIR; skipping"
        continue
      fi
      echo "  -> Using provided swatch $SRC"
      install -m 0644 "$SRC" "$SWATCH_PATH"
      # Badge optional; try copy if exists (same color square if provided)
      [ -r "$SWATCHES_DIR/${FN}_logo.png" ] && install -m 0644 "$SWATCHES_DIR/${FN}_logo.png" "$BADGE_PATH" || true
    fi

    URI="file://$SWATCH_PATH"
    MAP_NAME_TO_URI["$NAME"]="$URI"
    MAP_NAME_TO_BG["$NAME"]="$SWATCH_PATH"
    MAP_NAME_TO_LOGO["$NAME"]="$BADGE_PATH"

    [ -z "$FALLBACK_URI" ] && FALLBACK_URI="$URI"
    [ -z "$FALLBACK_BG_PATH" ] && FALLBACK_BG_PATH="$SWATCH_PATH"
  done

  # Fallback override (color) still supported when generating
  fb="${CLI_FALLBACK:-}"
  if [ -n "$fb" ] && [ "$USE_SWATCHES" != "true" ]; then
    if ! is_hex "$fb"; then
      echo "  !! Invalid fallback color: $fb" >&2
      exit 1
    fi
    if [ -z "$FALLBACK_BG_PATH" ]; then
      FN="fallback"
      SWATCH_PATH="$WALLPAPER_DIR/$FN.png"
      BADGE_PATH="$BADGE_DIR/${FN}_logo.png"
      echo "  -> Generating fallback swatch $SWATCH_PATH with color $fb"
      convert -size 2560x1440 "xc:${fb}" "$SWATCH_PATH"
      chmod 644 "$SWATCH_PATH"
      echo "  -> Generating fallback badge  $BADGE_PATH with color $fb"
      convert -size 128x128 "xc:${fb}" "$BADGE_PATH"
      chmod 644 "$BADGE_PATH"
      FALLBACK_URI="file://$SWATCH_PATH"
      FALLBACK_BG_PATH="$SWATCH_PATH"
    else
      FALLBACK_URI="file://$FALLBACK_BG_PATH"
    fi
  fi
else
  echo "For each connection, enter a hex color like #RRGGBB, press ENTER for default, or type 'skip' to ignore."
  echo "Installer will create: 2560x1440 swatch + 128x128 badge."
  echo
  echo "Example colors (name and hex):"
  echo "  - Green  #0e6625"
  echo "  - Blue   #00529b"
  echo "  - Red    #b20021"
  echo "  - Orange #ff8c00"
  echo "  - Purple #6a0dad"
  echo "  - Gold   #c9a227"
  echo "  - Gray   #808080"
  echo

  for NAME in "${CONNECTIONS[@]}"; do
    DEF="$(default_color_for "$NAME")"
    while true; do
      if [ "$USE_SWATCHES" = "true" ]; then
        FN="$(sanitize_filename "$NAME")"
        SRC="$SWATCHES_DIR/$FN.png"
        if [ -r "$SRC" ]; then
          echo "  -> Using provided swatch $SRC"
          install -m 0644 "$SRC" "$WALLPAPER_DIR/$FN.png"
          [ -r "$SWATCHES_DIR/${FN}_logo.png" ] && install -m 0644 "$SWATCHES_DIR/${FN}_logo.png" "$BADGE_DIR/${FN}_logo.png" || true
          URI="file://$WALLPAPER_DIR/$FN.png"
          MAP_NAME_TO_URI["$NAME"]="$URI"
          MAP_NAME_TO_BG["$NAME"]="$WALLPAPER_DIR/$FN.png"
          MAP_NAME_TO_LOGO["$NAME"]="$BADGE_DIR/${FN}_logo.png"
          [ -z "$FALLBACK_URI" ] && FALLBACK_URI="$URI"
          [ -z "$FALLBACK_BG_PATH" ] && FALLBACK_BG_PATH="$WALLPAPER_DIR/$FN.png"
          break
        else
          echo "  -> No PNG found for \"$NAME\" in $SWATCHES_DIR; type 'skip' to ignore or press ENTER to try default generation."
        fi
      fi

      read -r -p "Color for \"$NAME\" [default ${DEF}] (or 'skip'): " REPLY || REPLY=""
      REPLY="${REPLY:-$DEF}"
      if [[ "$REPLY" =~ ^[sS][kK][iI][pP]$ ]]; then
        echo "  -> Skipping \"$NAME\""
        break
      fi
      if is_hex "$REPLY"; then
        FN="$(sanitize_filename "$NAME")"
        SWATCH_PATH="$WALLPAPER_DIR/$FN.png"
        BADGE_PATH="$BADGE_DIR/${FN}_logo.png"

        echo "  -> Generating swatch $SWATCH_PATH with color $REPLY"
        convert -size 2560x1440 "xc:${REPLY}" "$SWATCH_PATH"
        chmod 644 "$SWATCH_PATH"

        echo "  -> Generating badge  $BADGE_PATH with color $REPLY"
        convert -size 128x128 "xc:${REPLY}" "$BADGE_PATH"
        chmod 644 "$BADGE_PATH"

        URI="file://$SWATCH_PATH"
        MAP_NAME_TO_URI["$NAME"]="$URI"
        MAP_NAME_TO_BG["$NAME"]="$SWATCH_PATH"
        MAP_NAME_TO_LOGO["$NAME"]="$BADGE_PATH"

        [ -z "$FALLBACK_URI" ] && FALLBACK_URI="$URI"
        [ -z "$FALLBACK_BG_PATH" ] && FALLBACK_BG_PATH="$SWATCH_PATH"
        break
      else
        echo "  !! Invalid color. Use format #RRGGBB (e.g., #0e6625)."
      fi
    done
  done
fi

if [ "${#MAP_NAME_TO_URI[@]}" -eq 0 ]; then
  echo "No mappings defined (all skipped). Nothing to install." >&2
  exit 1
fi

# Build case items for mapping function(s)
MAPPING_CASE_USER=""
MAPPING_CASE_GDM_BG=""
MAPPING_CASE_GDM_LOGO=""
for NAME in "${!MAP_NAME_TO_URI[@]}"; do
  URI="${MAP_NAME_TO_URI[$NAME]}"
  BG="${MAP_NAME_TO_BG[$NAME]}"
  LG="${MAP_NAME_TO_LOGO[$NAME]}"

  ESC_NAME="${NAME//\\/\\\\}"; ESC_NAME="${ESC_NAME//\"/\\\"}"

  ESC_URI="${URI//\\/\\\\}";   ESC_URI="${ESC_URI//\"/\\\"}"
  ESC_BG="${BG//\\/\\\\}";     ESC_BG="${ESC_BG//\"/\\\"}"
  ESC_LG="${LG//\\/\\\\}";     ESC_LG="${ESC_LG//\"/\\\"}"

  MAPPING_CASE_USER+="    \"$ESC_NAME\") echo \"$ESC_URI\" ;;\n"
  MAPPING_CASE_GDM_BG+="    \"$ESC_NAME\") echo \"$ESC_BG\" ;;\n"
  MAPPING_CASE_GDM_LOGO+="    \"$ESC_NAME\") echo \"$ESC_LG\" ;;\n"
done

# -------- Install user-session dispatcher --------
echo
echo "Installing user-session dispatcher -> $DISPATCHER_PATH"
umask 022
cat >"$DISPATCHER_PATH" <<'HEADER'
#!/bin/bash
# GNOME lock/background by active connection (RHEL 8/9).
# Auto-detects the active local GNOME user; uses picture-URI swatches.
# Generated by install-nm-lockscreen-colors.sh

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

IFACE="$1"
STATUS="$2"

# ---- CONFIG (URIs are inserted by installer) ----
HEADER

echo "IMG_FALLBACK=\"${FALLBACK_URI}\"" >>"$DISPATCHER_PATH"

cat >>"$DISPATCHER_PATH" <<'HEADER2'
# React only to decisive events
TRIGGER_STATUSES="up vpn-up down vpn-down"

TAG="nm-lockscreen-color"
LOCKFILE="/run/nm-lockscreen-color.lock"
STATEFILE="/run/nm-lockscreen-color.last"

log() { /usr/bin/logger -t "$TAG" "$*"; }
in_list() { for i in $2; do [ "$i" = "$1" ] && return 0; done; return 1; }

# Serialize to avoid concurrent runs fighting each other
exec 9>"$LOCKFILE" || exit 0
flock -n 9 || exit 0

# Only handle decisive events
in_list "$STATUS" "$TRIGGER_STATUSES" || exit 0

# Debounce a bit so routes/connections settle
sleep 1

# --- Detect the active local GNOME (Wayland/X11) user ---
detect_gui_user() {
  local CAND=""
  while read -r SID UID USER SEAT _; do
    [ -z "$SID" ] && continue
    local TYPE ACTIVE REMOTE
    TYPE=$(/usr/bin/loginctl show-session "$SID" -p Type --value 2>/dev/null)
    ACTIVE=$(/usr/bin/loginctl show-session "$SID" -p Active --value 2>/dev/null)
    REMOTE=$(/usr/bin/loginctl show-session "$SID" -p Remote --value 2>/dev/null)
    if [ "$ACTIVE" = "yes" ] && [ "$REMOTE" = "no" ] && { [ "$TYPE" = "wayland" ] || [ "$TYPE" = "x11" ]; }; then
      if /usr/bin/pgrep -u "$USER" -x gnome-shell >/dev/null 2>&1; then
        [ "$SEAT" = "seat0" ] && { echo "$USER"; return 0; }
        [ -z "$CAND" ] && CAND="$USER"
      fi
    fi
  done < <(/usr/bin/loginctl list-sessions --no-legend 2>/dev/null)

  if [ -z "$CAND" ]; then
    CAND=$(/usr/bin/ps -C gnome-shell -o user= --sort=etimes 2>/dev/null | head -n1)
  fi
  if [ -z "$CAND" ]; then
    for d in /run/user/*; do
      [ -S "$d/bus" ] || continue
      local uid user
      uid=$(basename "$d")
      user=$(/usr/bin/id -nu "$uid" 2>/dev/null || true)
      [ -n "$user" ] && { CAND="$user"; break; }
    done
  fi

  [ -n "$CAND" ] && { echo "$CAND"; return 0; }
  return 1
}

setup_user_bus_env() {
  local user="$1" uid
  uid=$(/usr/bin/id -u "$user" 2>/dev/null) || return 1
  export XDG_RUNTIME_DIR="/run/user/${uid}"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
  [ -S "${XDG_RUNTIME_DIR}/bus" ] || return 2
  return 0
}

apply_image() {
  local user="$1" img="$2"
  /usr/sbin/runuser -u "$user" -- /usr/bin/gsettings set org.gnome.desktop.screensaver picture-options 'scaled'
  /usr/sbin/runuser -u "$user" -- /usr/bin/gsettings set org.gnome.desktop.screensaver picture-uri "$img"
  /usr/sbin/runuser -u "$user" -- /usr/bin/gsettings set org.gnome.desktop.background picture-options 'scaled'
  /usr/sbin/runuser -u "$user" -- /usr/bin/gsettings set org.gnome.desktop.background picture-uri "$img"
  /usr/sbin/runuser -u "$user" -- /usr/bin/gsettings set org.gnome.desktop.background picture-uri-dark "$img" 2>/dev/null || true
}

pick_active_connection() {
  local vpn_name def_dev
  vpn_name=$(/usr/bin/nmcli -t -f NAME,TYPE connection show --active | awk -F: '$2=="vpn"{print $1; exit}')
  if [ -n "$vpn_name" ]; then echo "$vpn_name"; return; fi
  def_dev=$(/usr/sbin/ip route show default 2>/dev/null | awk '{print $5; exit}')
  if [ -n "$def_dev" ]; then
    /usr/bin/nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v d="$def_dev" '$2==d{print $1; exit}'
    return
  fi
  /usr/bin/nmcli -t -f NAME connection show --active | head -n1
}

# Mapping inserted by installer:
pick_image_for_conn() {
  case "$1" in
