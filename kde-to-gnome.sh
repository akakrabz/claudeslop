#!/usr/bin/env bash
#
# kde-to-gnome.sh — replace KDE Plasma with GNOME on Arch Linux
#
# Run it from a text console, NOT from a terminal inside Plasma:
#   1. Press Ctrl+Alt+F3 and log in
#   2. sudo bash kde-to-gnome.sh --dry-run    # preview, changes nothing
#   3. sudo bash kde-to-gnome.sh              # do it
#
# Order of operations (every step is safe to re-run if something fails):
#   pre-flight checks → stop the login manager → full system upgrade →
#   keep networking/audio/Bluetooth/printing/fonts from being swept away with
#   KDE → install the GNOME group → switch the login manager to GDM → remove
#   Plasma, KDE apps and SDDM / Plasma Login Manager → remove orphans → move
#   KDE-written GTK settings aside and reset GNOME theme keys → reboot.
#
# Version-agnostic on purpose: it installs whatever GNOME is current in [extra]
# and removes whatever is in the plasma / kde-* groups on your machine.

# Re-exec under bash if started from zsh or sh
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_NAME=kde-to-gnome
TS=$(date +%Y%m%d-%H%M%S)
STATE_DIR=/var/log/$SCRIPT_NAME/$TS
readonly SCRIPT_NAME TS STATE_DIR
LOG="" DM_STOPPED=0

usage() {
  cat <<'EOF'
Usage: sudo bash kde-to-gnome.sh [options]

  -n, --dry-run          Show the plan and the KDE packages found; change nothing
  -y, --yes              Don't stop at prompts (pacman runs with --noconfirm)
      --extra            Also install the gnome-extra group (Tweaks, etc.)
      --keep-apps        Remove only the Plasma desktop; keep KDE apps
                         (Dolphin, Kate, Okular, Konsole...)
      --purge-kde-config Also move ALL KDE/Plasma config out of your home
                         (to a backup folder, not deleted)
      --keep-user-config Don't touch anything in home directories
      --reboot           Reboot automatically at the end
      --force            Allow running from SSH / a non-VT terminal
  -h, --help             This help
EOF
}

ASSUME_YES=0 WITH_EXTRA=0 KEEP_APPS=0 CLEAN_USER=1 PURGE_KDE_CFG=0
AUTO_REBOOT=0 FORCE=0 DRY_RUN=0
ORIG_ARGS=("$@")
while (($#)); do
  case $1 in
    -n|--dry-run)        DRY_RUN=1 ;;
    -y|--yes)            ASSUME_YES=1 ;;
    --extra)             WITH_EXTRA=1 ;;
    --keep-apps)         KEEP_APPS=1 ;;
    --purge-kde-config)  PURGE_KDE_CFG=1 ;;
    --keep-user-config)  CLEAN_USER=0 ;;
    --reboot)            AUTO_REBOOT=1 ;;
    --force)             FORCE=1 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

if (( EUID != 0 )); then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -- bash "$(readlink -f -- "${BASH_SOURCE[0]}")" "${ORIG_ARGS[@]}"
  fi
  echo "Run this as root." >&2
  exit 1
fi

# ---------------------------------------------------------------- output ----
if [[ -t 1 ]]; then
  BOLD=$'\e[1m' RST=$'\e[0m' RED=$'\e[31m' GRN=$'\e[32m' YEL=$'\e[33m' BLU=$'\e[34m'
else
  BOLD="" RST="" RED="" GRN="" YEL="" BLU=""
fi

_log() { if [[ -n $LOG ]]; then printf '%s %s\n' "$(date +%T)" "$*" >>"$LOG"; fi; }
msg()  { printf '\n%s==>%s %s%s%s\n' "$BLU$BOLD" "$RST" "$BOLD" "$*" "$RST"; _log "==> $*"; }
info() { printf '    %s\n' "$*"; _log "    $*"; }
warn() { printf '%s  ! %s%s\n' "$YEL$BOLD" "$*" "$RST" >&2; _log "WARN $*"; }
die()  { printf '%s  ✗ %s%s\n' "$RED$BOLD" "$*" "$RST" >&2; _log "FATAL $*"; exit 1; }

# ask "question" [Y|N default] [1 = ask even with --yes]
ask() {
  local q=$1 def=${2:-N} always=${3:-0} hint reply=""
  if (( ASSUME_YES && ! always )); then return 0; fi
  if [[ $def == Y ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "$(printf '%s%s %s%s ' "$BOLD" "$q" "$hint" "$RST")" reply </dev/tty || reply=""
  reply=${reply:-$def}
  [[ $reply == [Yy]* ]]
}

on_err() {
  local rc=$? line=${1:-?} cmd=$BASH_COMMAND
  if (( BASH_SUBSHELL > 0 )); then exit "$rc"; fi
  trap - ERR
  printf '\n%s✗ Failed (exit %s) at line %s:%s %s\n' "$RED$BOLD" "$rc" "$line" "$RST" "$cmd" >&2
  _log "FAILED rc=$rc line=$line cmd=$cmd"
  if (( DM_STOPPED )); then
    printf '\n  You are still in a working console. To get a graphical login back now:\n      systemctl start display-manager\n' >&2
  fi
  printf '\n  Fix whatever is reported above, then run this script again — every step\n  is safe to repeat.\n' >&2
  if [[ -n $LOG ]]; then printf '  Log: %s\n' "$LOG" >&2; fi
  exit "$rc"
}
trap 'on_err $LINENO' ERR
trap 'printf "\n"; warn "Interrupted."; exit 130' INT

# ----------------------------------------------------------------- lists ----
# Installed as dependencies of Plasma on many systems; mark them explicit so
# removing KDE doesn't take your network, sound, Bluetooth or fonts with it.
PROTECT=(
  networkmanager iwd wpa_supplicant modemmanager
  bluez bluez-utils
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
  power-profiles-daemon tuned-ppd
  cups sane ipp-usb fwupd flatpak plymouth
  xdg-user-dirs xdg-utils
)

# Picked up in addition to the plasma / kde-* package groups
KDE_EXTRA_PKGS=(
  plasma-meta plasma-desktop plasma-workspace plasma-x11-session kwin-x11
  sddm sddm-kcm plasma-login-manager xdg-desktop-portal-kde kde-gtk-config
)
KDE_DM_UNITS=(sddm.service plasmalogin.service)

# Files KDE writes that make GNOME/libadwaita look wrong (Breeze colours,
# missing cursor/icon themes). Moved aside, never deleted.
# Note: ~/.config/gtk-3.0/bookmarks (your Files sidebar) is deliberately kept.
GTK_FILES=(
  .gtkrc-2.0 .config/gtkrc .config/gtkrc-2.0 .config/xsettingsd
  .config/gtk-3.0/settings.ini .config/gtk-3.0/gtk.css .config/gtk-3.0/colors.css
  .config/gtk-3.0/window_decorations.css .config/gtk-3.0/assets
  .config/gtk-4.0/settings.ini .config/gtk-4.0/gtk.css .config/gtk-4.0/colors.css
  .config/gtk-4.0/window_decorations.css .config/gtk-4.0/assets
)

# --purge-kde-config: Plasma desktop state (globs are expanded per home dir)
KDE_DESKTOP_CFG=(
  .config/kdeglobals '.config/kded*' '.config/kwin*' .config/kglobalshortcutsrc
  .config/khotkeysrc .config/kscreenlockerrc .config/ksmserverrc .config/ksplashrc
  .config/kcminputrc '.config/kactivitymanagerd*' .config/kxkbrc .config/krunnerrc
  .config/ktimezonedrc .config/kwalletrc .config/kconf_updaterc '.config/plasma*'
  .config/powerdevilrc .config/powermanagementprofilesrc .config/baloofilerc
  .config/systemsettingsrc .config/breezerc .config/oxygenrc .config/kcmfonts
  .config/kfontinstuirc .config/kiorc .config/kioslaverc .config/klipperrc
  .config/kde-mimeapps.list .config/bluedevilglobalrc .config/device_automounter_kcmrc
  .config/kgammarc .config/kmenueditrc .config/kaccessrc .config/kservicemenurc
  .config/Trolltech.conf
  .local/share/kactivitymanagerd .local/share/baloo .local/share/kscreen
  .local/share/kwalletd '.local/share/plasma*' .local/share/kded6 '.local/share/kwin*'
  .local/share/klipper .local/share/krunnerstaterc .local/share/kcookiejar
  .local/share/RecentDocuments .local/share/systemsettings
  '.cache/plasma*' '.cache/kwin*' '.cache/ksycoca*' '.cache/ksvg-elements*'
  .cache/icon-cache.kcache '.cache/krunner*' '.cache/kscreen*' '.cache/org.kde.*'
  .cache/kcrash-metadata
)
# --purge-kde-config without --keep-apps: KDE app settings too
KDE_APP_CFG=(
  .config/dolphinrc .config/konsolerc .config/konsolesshconfig '.config/kate*'
  .config/okularrc .config/okularpartrc .config/gwenviewrc .config/arkrc
  .config/spectaclerc .config/kwriterc .config/filelightrc .config/partitionmanagerrc
  .config/kdeconnect
  .local/share/dolphin .local/share/konsole .local/share/kate .local/share/okular
  .local/share/gwenview .local/share/kxmlgui5
)

# GNOME keys that KDE's GTK sync overwrites (Breeze theme, breeze icons/cursor,
# Noto 10pt, scaling, KDE-style titlebar buttons). Reset to GNOME defaults.
# shellcheck disable=SC2016  # expanded later by the user's shell, not here
RESET_SNIPPET='for k in gtk-theme icon-theme cursor-theme cursor-size font-name document-font-name monospace-font-name text-scaling-factor; do
  gsettings reset org.gnome.desktop.interface "$k"
done
gsettings reset org.gnome.desktop.wm.preferences button-layout'

# ----------------------------------------------------------------- state ----
TARGETS=() REMOVAL_LIST=() WARNINGS=()
OLD_DM="" HAVE_SNAPPER=0 KDE_STATE=none KDE_USERS=()
PAC_CONFIRM=()
if (( ASSUME_YES )); then PAC_CONFIRM=(--noconfirm); fi

# --------------------------------------------------------------- helpers ----
collect_kde_targets() {
  local re='^(plasma|kde-.+)$' p n
  if (( KEEP_APPS )); then re='^plasma$'; fi
  {
    pacman -Qg 2>/dev/null | awk -v re="$re" '$1 ~ re { print $2 }' || true
    if (( ! KEEP_APPS )); then
      pacman -Qq 2>/dev/null | grep -E '^kde-.+-meta$' || true
    fi
    for p in "${KDE_EXTRA_PKGS[@]}"; do
      if n=$(pacman -Qq "$p" 2>/dev/null); then printf '%s\n' "$n"; fi
    done
  } | sort -u
}

remove_from_targets() {
  local -A drop=()
  local -a keep=()
  local x
  for x in "$@"; do drop[$x]=1; done
  for x in "${TARGETS[@]}"; do
    if [[ -z ${drop[$x]:-} ]]; then keep+=("$x"); fi
  done
  TARGETS=("${keep[@]}")
}

# Dry-run the removal; if pacman says "removing X breaks dependency required
# by Y", either keep X (--keep-apps, or you say no) or add Y and try again.
resolve_removal() {
  local out answer=""
  local -a pairs blocked dependents
  for _ in {1..25}; do
    if (( ${#TARGETS[@]} == 0 )); then return 0; fi
    # -n (--nosave) can't be combined with --print, and it doesn't change which
    # packages go anyway, so the dry run uses -Rs; the real removal uses -Rns.
    if out=$(LC_ALL=C pacman -Rs --print --print-format '%n' "${TARGETS[@]}" 2>&1); then
      mapfile -t REMOVAL_LIST < <(grep -E '^[A-Za-z0-9@._+-]+$' <<<"$out" || true)
      return 0
    fi
    mapfile -t pairs < <(sed -nE "s/^:: removing ([^ ]+) breaks dependency '[^']*' required by ([^ ]+)\$/\\1 \\2/p" <<<"$out")
    if (( ${#pairs[@]} == 0 )); then
      printf '%s\n' "$out" >&2
      die "pacman refused the removal for a reason this script can't fix automatically (see above)."
    fi
    mapfile -t blocked    < <(printf '%s\n' "${pairs[@]%% *}" | sort -u)
    mapfile -t dependents < <(printf '%s\n' "${pairs[@]##* }" | sort -u)

    if (( KEEP_APPS )); then
      info "Keeping (needed by apps you're keeping): ${blocked[*]}"
      remove_from_targets "${blocked[@]}"
      continue
    fi
    if [[ -z $answer ]]; then
      warn "These packages aren't part of the KDE groups but depend on KDE pieces: ${dependents[*]}"
      if ask "Remove them too? (No = keep them plus the KDE bits they need)" N 1; then
        answer=y
      else
        answer=n
      fi
    fi
    if [[ $answer == y ]]; then
      info "Adding: ${dependents[*]}"
      TARGETS+=("${dependents[@]}")
      mapfile -t TARGETS < <(printf '%s\n' "${TARGETS[@]}" | sort -u)
    else
      info "Keeping: ${blocked[*]}"
      remove_from_targets "${blocked[@]}"
    fi
  done
  die "Couldn't settle the removal list after 25 rounds — remove the rest by hand with pacman -Rns."
}

rebuild_initramfs() {
  if command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P || warn "mkinitcpio reported errors — check its output above."
  elif command -v dracut >/dev/null 2>&1; then
    dracut --regenerate-all --force || warn "dracut reported errors — check its output above."
  else
    warn "Rebuild your initramfs manually so the new boot splash theme is included."
  fi
}

# ------------------------------------------------------------------ steps ---
preflight() {
  msg "Pre-flight checks"

  if [[ ! -f /etc/arch-release ]] || ! command -v pacman >/dev/null 2>&1; then
    die "This doesn't look like Arch Linux."
  fi
  local id="" pretty=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id=$(. /etc/os-release; printf '%s' "${ID:-}")
    # shellcheck disable=SC1091
    pretty=$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-}")
  fi
  if [[ $id != arch ]]; then
    WARNINGS+=("Detected '$pretty', not vanilla Arch — derivatives can use different package names.")
  fi

  local tty_dev
  tty_dev=$(tty 2>/dev/null || true)
  if (( ! FORCE && ! DRY_RUN )) && [[ $tty_dev != /dev/tty[0-9]* ]]; then
    die "Run this from a text console, not a terminal inside Plasma — stopping the login
     manager would kill this terminal mid-install. Press Ctrl+Alt+F3, log in, run it there.
     (Over SSH? Add --force.)"
  fi
  if (( ! ASSUME_YES && ! DRY_RUN )) && [[ ! -t 0 ]]; then
    die "No terminal on stdin — run the script directly, or pass --yes."
  fi

  if [[ -e /var/lib/pacman/db.lck ]]; then
    if pgrep -x pacman >/dev/null 2>&1; then
      die "pacman is already running. Let it finish first."
    fi
    die "Stale pacman lock. If no package manager is running: rm /var/lib/pacman/db.lck"
  fi

  local avail_kb
  avail_kb=$(df -Pk / | awk 'NR==2 { print $4 }')
  if (( avail_kb < 4 * 1024 * 1024 )); then
    WARNINGS+=("Only $(( avail_kb / 1024 )) MiB free on / — GNOME plus a full upgrade can need 3–4 GiB.")
  fi

  # Arch news 2026-09-22: mkinitcpio >= 42 changes TPM2 PCR measurements
  local mk
  mk=$(pacman -Q mkinitcpio 2>/dev/null | awk '{ print $2 }' || true)
  if [[ -n $mk ]] && (( $(vercmp "$mk" 42) < 0 )) \
     && grep -qs 'tpm2' /etc/crypttab /etc/crypttab.initramfs /etc/kernel/cmdline /proc/cmdline; then
    WARNINGS+=("TPM2 LUKS unlock detected, and this upgrade takes mkinitcpio $mk → 42+. Re-enroll the TPM2 afterwards (systemd-cryptenroll) or boot will ask for your passphrase.")
  fi

  # GNOME 50+ is Wayland-only and GDM always runs on Wayland: NVIDIA needs KMS
  if [[ -d /sys/module/nvidia ]]; then
    local ms
    ms=$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo unset)
    if [[ $ms != Y ]]; then
      WARNINGS+=("NVIDIA driver loaded but nvidia_drm.modeset=$ms. GNOME is Wayland-only now; add nvidia_drm.modeset=1 to your kernel cmdline or GDM won't start.")
    fi
  fi

  if [[ -L /etc/systemd/system/display-manager.service ]]; then
    OLD_DM=$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")
  fi

  if command -v snapper >/dev/null 2>&1 && snapper -c root list >/dev/null 2>&1; then
    HAVE_SNAPPER=1
  fi

  local u home
  while IFS=: read -r u home; do
    if [[ -e $home/.config/kdeglobals || -e $home/.config/plasma-org.kde.plasma.desktop-appletsrc ]]; then
      KDE_USERS+=("$u")
    fi
  done < <(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $1 ":" $6 }')

  mapfile -t TARGETS < <(collect_kde_targets)
  if (( ${#TARGETS[@]} == 0 )); then
    WARNINGS+=("No KDE/Plasma packages found — will just install GNOME and switch to GDM.")
  fi
}

print_plan() {
  local remove install users snap
  if (( KEEP_APPS )); then
    remove="Plasma desktop + its login manager (${#TARGETS[@]} packages); KDE apps stay"
  else
    remove="Plasma, all KDE apps, SDDM / Plasma Login Manager (${#TARGETS[@]} packages), then orphans"
  fi
  install="gnome group (current release from [extra])"
  if (( WITH_EXTRA )); then install+=" + gnome-extra"; fi
  if (( ! CLEAN_USER )); then
    users="untouched"
  elif (( ${#KDE_USERS[@]} == 0 )); then
    users="no KDE settings found in any home directory"
  else
    users="${KDE_USERS[*]}: KDE-written GTK theme files → ~/.kde-to-gnome-backup-$TS, GNOME theme/font keys reset"
    if (( PURGE_KDE_CFG )); then users+=", plus all KDE config moved there"; fi
  fi
  if (( HAVE_SNAPPER )); then snap="snapper snapshot of / first"; else snap="none (no snapper root config)"; fi

  msg "Plan"
  printf '    %-15s %s\n' \
    "Upgrade:"      "full pacman -Syu first (Arch doesn't do partial upgrades)" \
    "Install:"      "$install" \
    "Login screen:" "${OLD_DM:-none} → gdm.service" \
    "Remove:"       "$remove" \
    "Preserve:"     "networking, audio, Bluetooth, printing, fonts" \
    "Users:"        "$users" \
    "Snapshot:"     "$snap"
  if (( ! ASSUME_YES )); then
    info ""
    info "pacman will still ask before each install/removal — Enter accepts its defaults."
  fi
  local w
  for w in "${WARNINGS[@]}"; do warn "$w"; done
}

save_state() {
  mkdir -p "$STATE_DIR"
  LOG=$STATE_DIR/run.log
  _log "$SCRIPT_NAME started with: ${ORIG_ARGS[*]:-<no options>}"
  pacman -Qqe >"$STATE_DIR/explicit-before.txt"
  pacman -Q   >"$STATE_DIR/all-before.txt"
  systemctl list-unit-files --state=enabled --no-pager >"$STATE_DIR/enabled-units-before.txt" || true
  printf '%s\n' "${OLD_DM:-none}" >"$STATE_DIR/old-display-manager.txt"
  info "Package lists and log: $STATE_DIR"
}

take_snapshot() {
  if (( ! HAVE_SNAPPER )); then return 0; fi
  msg "Taking a snapper snapshot of /"
  local n
  if n=$(snapper -c root create --type single --cleanup-algorithm number \
           --description "before $SCRIPT_NAME" --print-number 2>&1); then
    info "Snapshot #$n"
  else
    warn "snapper failed ($n) — continuing without a snapshot."
  fi
}

stop_graphical() {
  DM_STOPPED=1
  if systemctl is-active --quiet display-manager.service; then
    msg "Stopping ${OLD_DM:-the display manager} (this ends any Plasma session)"
    systemctl stop display-manager.service
  fi
  if pgrep -x 'plasmashell|kwin_wayland|kwin_x11|ksmserver' >/dev/null 2>&1; then
    info "Stopping leftover Plasma processes"
    pkill -TERM -x 'plasmashell|kwin_wayland|kwin_x11|ksmserver' || true
    sleep 3
  fi
}

# Done while the old desktop still works, so a dead network fails early
refresh_keyring() {
  msg "Refreshing databases and keyring"
  pacman -Sy --needed --noconfirm archlinux-keyring
}

upgrade_system() {
  msg "Full system upgrade"
  pacman -Su "${PAC_CONFIRM[@]}"
}

protect_essentials() {
  local -a deps=() mark=()
  local -A isdep=()
  local p
  mapfile -t deps < <(pacman -Qdq 2>/dev/null || true)
  for p in "${deps[@]}"; do isdep[$p]=1; done
  for p in "${PROTECT[@]}"; do
    if [[ -n ${isdep[$p]:-} ]]; then mark+=("$p"); fi
  done
  for p in "${deps[@]}"; do
    if [[ $p == ttf-* || $p == otf-* || $p == noto-fonts* ]]; then mark+=("$p"); fi
  done
  if (( ${#mark[@]} == 0 )); then return 0; fi
  mapfile -t mark < <(printf '%s\n' "${mark[@]}" | sort -u)
  msg "Marking ${#mark[@]} system packages as explicitly installed so they survive KDE's removal"
  info "${mark[*]}"
  pacman -D --asexplicit "${mark[@]}" >/dev/null
}

install_gnome() {
  local -a pkgs=(gnome)
  if (( WITH_EXTRA )); then pkgs+=(gnome-extra); fi
  msg "Installing ${pkgs[*]}"
  pacman -S --needed "${PAC_CONFIRM[@]}" "${pkgs[@]}"
}

switch_dm() {
  msg "Switching the login manager to GDM"
  local unit
  for unit in "${KDE_DM_UNITS[@]}" ${OLD_DM:+"$OLD_DM"}; do
    if [[ $unit == gdm.service ]]; then continue; fi
    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      systemctl disable "$unit"
    fi
  done
  systemctl enable --force gdm.service
  if [[ $(systemctl get-default) != graphical.target ]]; then
    systemctl set-default graphical.target
  fi
}

remove_kde() {
  mapfile -t TARGETS < <(collect_kde_targets)   # re-scan after the upgrade
  if (( ${#TARGETS[@]} == 0 )); then
    info "No KDE packages to remove."
    return 0
  fi
  msg "Removing KDE"
  resolve_removal
  if (( ${#TARGETS[@]} == 0 )); then
    info "Nothing left to remove."
    return 0
  fi
  printf '%s\n' "${REMOVAL_LIST[@]}" >"$STATE_DIR/removed-packages.txt"
  info "${#REMOVAL_LIST[@]} packages will go (KDE plus dependencies nothing else needs)."
  if pacman -Rns "${PAC_CONFIRM[@]}" "${TARGETS[@]}"; then
    KDE_STATE=removed
  else
    KDE_STATE=kept
    warn "KDE removal didn't go through (declined or failed). GNOME + GDM are set up regardless."
  fi
}

remove_orphans() {
  if [[ $KDE_STATE != removed ]]; then return 0; fi
  local -a orphans=()
  mapfile -t orphans < <(pacman -Qdtq 2>/dev/null || true)
  if (( ${#orphans[@]} == 0 )); then return 0; fi
  msg "Removing ${#orphans[@]} orphaned packages"
  pacman -Rns "${PAC_CONFIRM[@]}" "${orphans[@]}" || warn "Orphan cleanup skipped."
}

fix_plymouth() {
  if ! command -v plymouth-set-default-theme >/dev/null 2>&1; then return 0; fi
  local cur
  cur=$(plymouth-set-default-theme 2>/dev/null || true)
  if [[ -z $cur || -d /usr/share/plymouth/themes/$cur ]]; then return 0; fi
  msg "Boot splash theme '$cur' went with KDE — resetting to the default"
  plymouth-set-default-theme --reset
  rebuild_initramfs
}

reset_user_keys() {
  local u=$1 home=$2 grp
  grp=$(id -gn "$u")
  if command -v dbus-run-session >/dev/null 2>&1 \
     && ( cd / && runuser -u "$u" -- env -i HOME="$home" USER="$u" LOGNAME="$u" \
            PATH=/usr/local/bin:/usr/bin dbus-run-session -- sh -c "$RESET_SNIPPET" ) \
          </dev/null >/dev/null 2>&1; then
    info "  reset GNOME theme/font keys"
    return 0
  fi
  # Fallback: one-shot autostart that runs on first GNOME login, then deletes itself
  local adir=$home/.config/autostart script=$home/.config/kde-to-gnome-reset.sh
  install -d -o "$u" -g "$grp" "$adir"
  # shellcheck disable=SC2016  # $HOME/$0 belong to the generated script
  printf '#!/bin/sh\n%s\nrm -f "$HOME/.config/autostart/kde-to-gnome-reset.desktop" "$0"\n' \
    "$RESET_SNIPPET" >"$script"
  printf '[Desktop Entry]\nType=Application\nName=Finish KDE to GNOME switch\nExec=sh "%s"\nNoDisplay=true\n' \
    "$script" >"$adir/kde-to-gnome-reset.desktop"
  chown "$u:$grp" "$script" "$adir/kde-to-gnome-reset.desktop"
  info "  GNOME theme/font keys will reset on first login"
}

cleanup_user() {
  local u=$1 home=$2 bdir rel p pat moved=0
  local -a pats=("${GTK_FILES[@]}")
  bdir=$home/.kde-to-gnome-backup-$TS
  if (( PURGE_KDE_CFG )); then
    pats+=("${KDE_DESKTOP_CFG[@]}")
    if (( ! KEEP_APPS )); then pats+=("${KDE_APP_CFG[@]}"); fi
  fi
  info "$u:"
  for pat in "${pats[@]}"; do
    # shellcheck disable=SC2086  # intentional glob expansion of $pat
    for p in "$home"/$pat; do
      if [[ ! -e $p && ! -L $p ]]; then continue; fi
      rel=${p#"$home"/}
      mkdir -p -- "$bdir/$(dirname -- "$rel")"
      mv -- "$p" "$bdir/$rel"
      moved=$(( moved + 1 ))
    done
  done
  if (( moved )); then
    chown -R "$u:$(id -gn "$u")" "$bdir"
    chmod 700 "$bdir"
    info "  moved $moved item(s) to ~/.kde-to-gnome-backup-$TS"
  fi
  reset_user_keys "$u" "$home"
}

user_cleanup() {
  if (( ! CLEAN_USER )) || [[ $KDE_STATE == kept ]] || (( ${#KDE_USERS[@]} == 0 )); then
    return 0
  fi
  msg "Clearing KDE leftovers from user settings (moved to a backup folder, not deleted)"
  local u home
  for u in "${KDE_USERS[@]}"; do
    home=$(getent passwd "$u" | cut -d: -f6)
    if [[ -n $home && $home != / && -d $home ]]; then cleanup_user "$u" "$home"; fi
  done
}

post_checks() {
  msg "Final checks"
  local hits
  local -a envfiles=(/etc/environment /etc/environment.d/*.conf /etc/profile.d/*.sh)
  hits=$(grep -lsE 'QT_QPA_PLATFORMTHEME=.*(kde|plasma)|XDG_CURRENT_DESKTOP=KDE|KDE_SESSION' \
           "${envfiles[@]}" 2>/dev/null || true)
  if [[ -n $hits ]]; then
    warn "KDE environment variables still set in: $(tr '\n' ' ' <<<"$hits")— remove them."
  fi
  hits=$(grep -ls 'pam_kwallet' /etc/pam.d/* 2>/dev/null || true)
  if [[ -n $hits ]]; then
    warn "PAM still loads pam_kwallet (now removed) in: $(tr '\n' ' ' <<<"$hits")— delete those lines."
  fi
  if grep -qsiE '^[[:space:]]*WaylandEnable[[:space:]]*=[[:space:]]*false' /etc/gdm/custom.conf; then
    warn "/etc/gdm/custom.conf has WaylandEnable=false — GDM is Wayland-only now; remove that line."
  fi
  if pacman -Q networkmanager >/dev/null 2>&1 && ! systemctl is-enabled --quiet NetworkManager.service; then
    warn "NetworkManager is installed but not enabled; GNOME's network settings need it (systemctl enable NetworkManager)."
  fi
  if systemctl is-enabled --quiet gdm.service; then
    info "gdm.service enabled ✓"
  else
    warn "gdm.service is not enabled — run: systemctl enable --force gdm.service"
  fi
}

finish() {
  msg "${GRN}Done.${RST}${BOLD} $(pacman -Q gnome-shell 2>/dev/null || echo 'gnome-shell ?') installed"
  info "Log and before/after package lists: $STATE_DIR"
  if (( CLEAN_USER && ${#KDE_USERS[@]} )) && [[ $KDE_STATE != kept ]]; then
    info "Old KDE/GTK settings: ~/.kde-to-gnome-backup-$TS (delete once you're happy)"
  fi
  if (( AUTO_REBOOT )) || { (( ! ASSUME_YES )) && ask "Reboot now?" Y; }; then
    sync
    systemctl reboot
  else
    info "Reboot when ready: systemctl reboot"
  fi
}

# ------------------------------------------------------------------- main ---
main() {
  preflight
  print_plan

  if (( DRY_RUN )); then
    msg "KDE packages that would be removed (top level; dependencies follow automatically)"
    if (( ${#TARGETS[@]} )); then
      if command -v column >/dev/null 2>&1; then
        printf '%s\n' "${TARGETS[@]}" | column -c "${COLUMNS:-100}"
      else
        printf '    %s\n' "${TARGETS[@]}"
      fi
    fi
    info ""
    info "Dry run — nothing was changed."
    exit 0
  fi

  printf '\n'
  if ! ask "Go ahead?" N; then
    info "Aborted — nothing was changed."
    exit 0
  fi

  save_state
  take_snapshot
  refresh_keyring
  stop_graphical
  upgrade_system
  protect_essentials
  install_gnome
  switch_dm
  remove_kde
  remove_orphans
  fix_plymouth
  user_cleanup
  post_checks
  finish
}

main
