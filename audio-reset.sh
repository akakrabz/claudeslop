#!/usr/bin/env bash
#
# audio-reset.sh — wipe every sound server on Arch Linux and install one clean stack
#
#   sudo bash audio-reset.sh --dry-run    # show what it would do, change nothing
#   sudo bash audio-reset.sh              # asks: PipeWire (recommended) or ALSA
#   sudo bash audio-reset.sh --pipewire   # or: --alsa
#
# Fine to run from a terminal inside your desktop — sound drops for a few seconds.
#
# PipeWire mode
#   Removes PulseAudio (+ its modules), JACK2, pipewire-media-session and other
#   competing servers. Moves every custom audio config (system-wide and in each
#   home folder) into a backup. Reinstalls the full PipeWire stack from scratch
#   (every file rewritten) plus ALSA tools and firmware, re-enables the user
#   services, restarts audio for everyone logged in and checks that it works.
#
# ALSA mode
#   Removes every sound server it can. Anything your desktop hard-depends on
#   (GNOME needs pipewire, wireplumber and pipewire-pulse) stays installed but is
#   cut off from the hardware: WirePlumber stops opening sound cards and
#   Bluetooth, and the PulseAudio socket is masked, so programs use ALSA directly.

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

set -Eeuo pipefail
shopt -s nullglob

NAME=audio-reset
TS=$(date +%Y%m%d-%H%M%S)
STATE_DIR=/var/log/$NAME/$TS
readonly NAME TS STATE_DIR
LOG="" PHASE=start

usage() {
  cat <<'EOF'
Usage: sudo bash audio-reset.sh [options]

      --pipewire          Clean PipeWire install (recommended, default)
      --alsa              ALSA only: no sound server touches the hardware
  -n, --dry-run           Show the plan; change nothing
  -y, --yes               Don't stop at prompts (pacman runs with --noconfirm)
      --keep-user-config  Leave per-user audio config in home folders alone
      --reboot            Reboot at the end (ALSA mode recommends it)
  -h, --help              This help
EOF
}

MODE="" DRY_RUN=0 ASSUME_YES=0 CLEAN_USER=1 AUTO_REBOOT=0
ORIG_ARGS=("$@")
while (($#)); do
  case $1 in
    --pipewire)          MODE=pipewire ;;
    --alsa)              MODE=alsa ;;
    -n|--dry-run)        DRY_RUN=1 ;;
    -y|--yes)            ASSUME_YES=1 ;;
    --keep-user-config)  CLEAN_USER=0 ;;
    --reboot)            AUTO_REBOOT=1 ;;
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
good() { printf '    %s✓%s %s\n' "$GRN" "$RST" "$*"; _log " OK $*"; }
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
  _log "FAILED rc=$rc line=$line phase=$PHASE cmd=$cmd"
  if [[ $PHASE == servers-removed ]]; then
    printf '\n  The old sound servers are gone but PipeWire is not reinstalled yet.\n  Get sound back with:\n      pacman -S pipewire pipewire-audio pipewire-pulse pipewire-alsa pipewire-jack wireplumber\n' >&2
  fi
  printf '\n  Fix what is reported above and run the script again — every step is safe\n  to repeat.\n' >&2
  if [[ -n $LOG ]]; then printf '  Log and config backups: %s\n' "$STATE_DIR" >&2; fi
  exit "$rc"
}
trap 'on_err $LINENO' ERR
trap 'printf "\n"; warn "Interrupted."; exit 130' INT

# ----------------------------------------------------------------- lists ----
# Sound servers that compete with PipeWire. Removed in both modes.
COMPETITORS=(
  pulseaudio pulseaudio-alsa pulseaudio-bluetooth pulseaudio-equalizer pulseaudio-jack
  pulseaudio-lirc pulseaudio-rtp pulseaudio-zeroconf
  jack jack2 jack2-dbus lib32-jack lib32-jack2
  pipewire-media-session pipewire-jack-client pipewire-system-services
  wireplumber-system-services apulse
)
# The PipeWire stack (PipeWire mode installs these)
PW_STACK=(pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack wireplumber rtkit)
# Reinstalled too, if you already have them
PW_EXTRAS=(
  libpipewire libwireplumber alsa-card-profiles gst-plugin-pipewire pipewire-zeroconf
  pipewire-roc pipewire-ffado pipewire-netjack2 pipewire-x11-bell pipewire-v4l2
  pipewire-libcamera pipewire-onnx pipewire-docs lib32-pipewire lib32-pipewire-v4l2
  lib32-libpulse
)
# ALSA mode tries to remove these (whatever the desktop doesn't depend on)
ALSA_MODE_REMOVE=(
  pipewire-alsa pipewire-pulse pipewire-jack pipewire-audio pipewire wireplumber
  pipewire-zeroconf pipewire-roc pipewire-ffado pipewire-netjack2 pipewire-x11-bell
  pipewire-onnx lib32-pipewire-jack lib32-pipewire
)
# Both modes: ALSA userspace (always) and firmware (when your repos have it)
ALSA_BASE=(alsa-lib alsa-utils alsa-ucm-conf)
ALSA_FIRMWARE=(alsa-firmware sof-firmware)

# System config moved to $STATE_DIR/config-backup (only files no package owns)
SYS_CFG=(
  /etc/pipewire /etc/wireplumber /etc/pulse /etc/jack /etc/asound.conf /etc/alsa/conf.d
  '/etc/systemd/user/pipewire*' '/etc/systemd/user/wireplumber*'
  '/etc/systemd/user/pulseaudio*' '/etc/systemd/user/jack*'
)
# Per-user config moved to ~/.audio-reset-backup-<time>
USER_CFG=(
  .config/pipewire .config/wireplumber .local/state/wireplumber .local/state/pipewire
  .config/pulse .pulse .pulse-cookie .esd_auth .asoundrc .asoundrc.asoundconf
  .jackdrc .config/jack
  '.config/systemd/user/pipewire*' '.config/systemd/user/wireplumber*'
  '.config/systemd/user/pulseaudio*' '.config/systemd/user/jack*'
  '.config/systemd/user/*.wants/pipewire*' '.config/systemd/user/*.wants/wireplumber*'
  '.config/systemd/user/*.wants/pulseaudio*'
)
AUDIO_UNITS=(
  pipewire-pulse.socket pipewire-pulse.service wireplumber.service
  pipewire.socket pipewire.service pulseaudio.socket pulseaudio.service
)
WP_ALSA_OFF=/etc/wireplumber/wireplumber.conf.d/90-audio-reset-alsa-only.conf
ASOUND=/proc/asound
ASOUND_CONF=/etc/asound.conf

# ----------------------------------------------------------------- state ----
declare -A INSTALLED=()
TARGETS=() REMOVAL_LIST=() KEPT=() ACTIVE_USERS=() HUMANS=() RUNNING=()
PAC_CONFIRM=()
if (( ASSUME_YES )); then PAC_CONFIRM=(--noconfirm); fi

# --------------------------------------------------------------- helpers ----
refresh_installed() {
  INSTALLED=()
  local p
  while read -r p; do INSTALLED[$p]=1; done < <(pacman -Qq 2>/dev/null || true)
}
installed() { [[ -n ${INSTALLED[$1]:-} ]]; }
available() { pacman -Si "$1" >/dev/null 2>&1; }
owned()     { pacman -Qoq "$1" >/dev/null 2>&1; }

# Names from the given list(s) that are installed, de-duplicated
installed_of() {
  local p
  for p in "$@"; do
    if installed "$p"; then printf '%s\n' "$p"; fi
  done | sort -u
}

# Every installed competitor, including AUR/-git pulseaudio variants
installed_competitors() {
  {
    installed_of "${COMPETITORS[@]}"
    printf '%s\n' "${!INSTALLED[@]}" | grep -E '^pulseaudio' | grep -vx 'pulseaudio-qt' || true
  } | sort -u
}

user_ctl() {   # user_ctl <user> <systemctl --user args...>
  local u=$1 uid
  shift
  uid=$(id -u "$u")
  ( cd / && runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" systemctl --user "$@" )
}

user_run() {   # user_run <user> <command...>
  local u=$1 uid
  shift
  uid=$(id -u "$u")
  ( cd / && runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@" )
}

backup_move() {   # backup_move <path> <backup root> <path relative to root>
  local src=$1 root=$2 rel=$3
  mkdir -p -- "$root/$(dirname -- "$rel")"
  mv -- "$src" "$root/$rel"
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

# ALSA mode: work out what can go. Anything another installed package needs
# ("removing X breaks dependency required by Y") is kept and neutralised later.
# Note: pacman refuses --nosave together with --print, so the dry run is -Rs.
resolve_removal() {
  local out
  local -a pairs blocked
  KEPT=()
  for _ in {1..25}; do
    if (( ${#TARGETS[@]} == 0 )); then REMOVAL_LIST=(); return 0; fi
    if out=$(LC_ALL=C pacman -Rs --print --print-format '%n' "${TARGETS[@]}" 2>&1); then
      mapfile -t REMOVAL_LIST < <(grep -E '^[A-Za-z0-9@._+-]+$' <<<"$out" || true)
      return 0
    fi
    mapfile -t pairs < <(sed -nE "s/^:: removing ([^ ]+) breaks dependency '[^']*' required by ([^ ]+)\$/\\1 \\2/p" <<<"$out")
    if (( ${#pairs[@]} == 0 )); then
      printf '%s\n' "$out" >&2
      die "pacman refused the removal for a reason this script can't work around (see above)."
    fi
    mapfile -t blocked < <(printf '%s\n' "${pairs[@]%% *}" | sort -u)
    KEPT+=("${blocked[@]}")
    remove_from_targets "${blocked[@]}"
  done
  die "Couldn't settle the removal list after 25 rounds."
}

# ------------------------------------------------------------------ steps ---
preflight() {
  msg "Pre-flight checks"
  if [[ ! -f /etc/arch-release ]] || ! command -v pacman >/dev/null 2>&1; then
    die "This doesn't look like Arch Linux."
  fi
  if [[ -e /var/lib/pacman/db.lck ]]; then
    if pgrep -x pacman >/dev/null 2>&1; then die "pacman is already running. Let it finish first."; fi
    die "Stale pacman lock. If no package manager is running: rm /var/lib/pacman/db.lck"
  fi
  if (( ! ASSUME_YES && ! DRY_RUN )) && [[ ! -t 0 ]]; then
    die "No terminal on stdin — run the script directly, or pass --yes."
  fi

  refresh_installed

  local name uid home
  while IFS=: read -r name uid home; do
    if [[ -d $home && $home != / ]]; then HUMANS+=("$name"); fi
  done < <(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $1 ":" $3 ":" $6 }')

  while read -r uid name; do
    if (( uid >= 1000 && uid < 60000 )) && [[ -S /run/user/$uid/bus ]]; then ACTIVE_USERS+=("$name"); fi
  done < <(loginctl list-users --no-legend 2>/dev/null | awk '{ print $1, $2 }' || true)

  mapfile -t RUNNING < <(pgrep -lx 'pulseaudio|pipewire|pipewire-pulse|wireplumber|jackd|jackdbus' | awk '{ print $2 }' | sort -u || true)
}

choose_mode() {
  if [[ -n $MODE ]]; then return 0; fi
  if (( ASSUME_YES || DRY_RUN )); then MODE=pipewire; return 0; fi
  printf '\n%sWhich audio stack do you want?%s\n' "$BOLD" "$RST"
  printf '  1) PipeWire  — recommended; GNOME, browsers, Bluetooth and screen\n'
  printf '                 recording all expect it. Low latency via its JACK API.\n'
  printf '  2) ALSA only — programs talk to the sound card directly, no sound server.\n'
  printf '                 Breaks GNOME volume controls and Bluetooth audio.\n'
  local c=""
  read -r -p "Choose [1]: " c </dev/tty || c=""
  case ${c:-1} in
    2) MODE=alsa ;;
    *) MODE=pipewire ;;
  esac
}

print_plan() {
  local -a comps
  mapfile -t comps < <(installed_competitors)
  msg "Current state"
  info "Running now:   ${RUNNING[*]:-no sound server}"
  info "Installed:     $(installed_of "${COMPETITORS[@]}" "${PW_STACK[@]}" "${PW_EXTRAS[@]}" | tr '\n' ' ')"
  info "Users:         ${HUMANS[*]:-none}   (logged in: ${ACTIVE_USERS[*]:-none})"

  msg "Plan — ${MODE^^} mode"
  info "1. Full system upgrade (pacman -Syu) so nothing is a partial upgrade"
  info "2. Stop audio for logged-in users"
  if (( CLEAN_USER )); then
    info "3. Move custom audio config aside: /etc → $STATE_DIR/config-backup,"
    info "   home folders → ~/.audio-reset-backup-$TS (also clears systemd masks)"
  else
    info "3. Move custom system audio config to $STATE_DIR/config-backup (home folders untouched)"
  fi
  if [[ $MODE == pipewire ]]; then
    info "4. Remove competing servers: ${comps[*]:-none installed}"
    info "5. Reinstall from scratch: ${PW_STACK[*]} $(installed_of "${PW_EXTRAS[@]}" | tr '\n' ' ')"
    info "   plus ${ALSA_BASE[*]} ${ALSA_FIRMWARE[*]}"
    if installed lib32-jack2 || installed lib32-jack; then
      info "   plus lib32-pipewire-jack (replaces 32-bit JACK for Steam/Wine)"
    fi
    if installed lib32-libpulse && ! installed lib32-pipewire; then
      info "   plus lib32-pipewire (32-bit apps)"
    fi
    info "6. Enable PipeWire for all users, restart audio, verify it works"
  else
    TARGETS=()
    mapfile -t TARGETS < <({ installed_competitors; installed_of "${ALSA_MODE_REMOVE[@]}"; } | sort -u)
    resolve_removal
    info "4. Remove: ${TARGETS[*]:-nothing removable}"
    if (( ${#KEPT[@]} )); then
      info "   Kept because other packages need them (disabled instead): $(printf '%s\n' "${KEPT[@]}" | sort -u | tr '\n' ' ')"
    fi
    info "5. Stop WirePlumber opening sound cards/Bluetooth; mask the PulseAudio socket"
    info "6. Reinstall ${ALSA_BASE[*]} ${ALSA_FIRMWARE[*]}; pick a default sound card"
    if installed gnome-settings-daemon || installed gnome-shell; then
      warn "GNOME in ALSA mode: no volume slider, volume keys, Sound settings or Bluetooth"
      warn "audio; screen recordings have no sound; apps that only speak PulseAudio go silent."
    fi
  fi
}

save_state() {
  mkdir -p "$STATE_DIR"
  LOG=$STATE_DIR/run.log
  _log "$NAME $MODE mode, options: ${ORIG_ARGS[*]:-<none>}"
  pacman -Q >"$STATE_DIR/packages-before.txt"
  info "Log, package list and config backups: $STATE_DIR"
}

upgrade_system() {
  msg "Refreshing keyring and upgrading the system"
  pacman -Sy --needed --noconfirm archlinux-keyring
  pacman -Su "${PAC_CONFIRM[@]}"
  refresh_installed
}

stop_audio() {
  msg "Stopping audio"
  local u unit
  for u in "${ACTIVE_USERS[@]}"; do
    for unit in "${AUDIO_UNITS[@]}"; do
      user_ctl "$u" stop "$unit" >/dev/null 2>&1 || true
    done
    pkill -u "$u" -x 'pulseaudio|jackd|jackdbus|pipewire|pipewire-pulse|wireplumber' 2>/dev/null || true
    info "stopped for $u"
  done
  pkill -x 'jackd|jackdbus' 2>/dev/null || true
}

purge_system_config() {
  msg "Moving custom system audio config aside"
  local pat path f moved=0 root=$STATE_DIR/config-backup
  for pat in "${SYS_CFG[@]}"; do
    # shellcheck disable=SC2086  # intentional glob expansion
    for path in $pat; do
      if [[ -d $path && ! -L $path ]]; then
        while IFS= read -r -d '' f; do
          if ! owned "$f"; then backup_move "$f" "$root" "${f#/}"; moved=$((moved + 1)); info "$f"; fi
        done < <(find "$path" \( -type f -o -type l \) -print0)
        find "$path" -mindepth 1 -type d -empty -delete 2>/dev/null || true
      elif [[ -e $path || -L $path ]] && ! owned "$path"; then
        backup_move "$path" "$root" "${path#/}"
        moved=$((moved + 1))
        info "$path"
      fi
    done
  done
  if (( moved == 0 )); then info "none found"; fi
}

purge_user_config() {
  if (( ! CLEAN_USER )); then return 0; fi
  msg "Moving per-user audio config aside"
  local u home grp pat p rel moved bdir
  for u in "${HUMANS[@]}"; do
    home=$(getent passwd "$u" | cut -d: -f6)
    grp=$(id -gn "$u")
    bdir=$home/.audio-reset-backup-$TS
    moved=0
    for pat in "${USER_CFG[@]}"; do
      # shellcheck disable=SC2086  # intentional glob expansion
      for p in "$home"/$pat; do
        if [[ ! -e $p && ! -L $p ]]; then continue; fi
        rel=${p#"$home"/}
        backup_move "$p" "$bdir" "$rel"
        moved=$((moved + 1))
      done
    done
    if (( moved )); then
      chown -R "$u:$grp" "$bdir"
      chmod 700 "$bdir"
      info "$u: moved $moved item(s) to ~/.audio-reset-backup-$TS"
    else
      info "$u: nothing to move"
    fi
  done
}

install_list() {   # prints what's installable from the given names; warns on the rest
  local p
  for p in "$@"; do
    if available "$p"; then printf '%s\n' "$p"; else warn "$p isn't in your enabled repos — skipping" >&2; fi
  done | sort -u
}

# ------------------------------------------------------------ pipewire -----
pipewire_mode() {
  local -a comps install before_orphans new_orphans
  local p

  mapfile -t comps < <(installed_competitors)
  mapfile -t before_orphans < <(pacman -Qdtq 2>/dev/null || true)

  # What to install: core stack, extras you already have, ALSA bits, firmware,
  # and the 32-bit JACK replacement if you had 32-bit JACK.
  local -a want=("${PW_STACK[@]}" "${ALSA_BASE[@]}" "${ALSA_FIRMWARE[@]}")
  mapfile -t -O "${#want[@]}" want < <(installed_of "${PW_EXTRAS[@]}")
  if installed lib32-jack2 || installed lib32-jack; then want+=(lib32-pipewire-jack); fi
  if installed lib32-libpulse && ! installed lib32-pipewire; then want+=(lib32-pipewire); fi
  mapfile -t install < <(install_list "${want[@]}")

  if (( ${#comps[@]} )); then
    msg "Removing competing sound servers"
    info "${comps[*]}"
    # -dd: other packages depend on "a PulseAudio/JACK server"; PipeWire provides
    # both and goes in right after, so that dependency is only broken for seconds.
    pacman -Rndd --noconfirm "${comps[@]}"
    PHASE=servers-removed
  fi

  msg "Installing the PipeWire stack (reinstalling anything already present)"
  pacman -S "${PAC_CONFIRM[@]}" "${install[@]}"
  PHASE=installed
  refresh_installed

  # Leftover libraries that only the removed servers used
  local -A was=()
  for p in "${before_orphans[@]}"; do was[$p]=1; done
  new_orphans=()
  while read -r p; do
    if [[ -n $p && -z ${was[$p]:-} ]]; then new_orphans+=("$p"); fi
  done < <(pacman -Qdtq 2>/dev/null || true)
  if (( ${#new_orphans[@]} )); then
    msg "Removing ${#new_orphans[@]} libraries only the old servers used"
    pacman -Rns "${PAC_CONFIRM[@]}" "${new_orphans[@]}" || warn "Skipped — remove later with: pacman -Rns \$(pacman -Qdtq)"
  fi

  msg "Enabling PipeWire for every user"
  systemctl --global unmask "${AUDIO_UNITS[@]:0:5}" >/dev/null 2>&1 || true
  systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
}

# ---------------------------------------------------------------- alsa -----
alsa_mode() {
  TARGETS=()
  mapfile -t TARGETS < <({ installed_competitors; installed_of "${ALSA_MODE_REMOVE[@]}"; } | sort -u)
  resolve_removal

  if (( ${#TARGETS[@]} )); then
    msg "Removing sound servers"
    printf '%s\n' "${REMOVAL_LIST[@]}" >"$STATE_DIR/removed-packages.txt"
    pacman -Rns "${PAC_CONFIRM[@]}" "${TARGETS[@]}"
  fi
  refresh_installed

  msg "Cutting the remaining sound servers off from the hardware"
  if installed wireplumber; then
    mkdir -p "$(dirname "$WP_ALSA_OFF")"
    cat >"$WP_ALSA_OFF" <<'EOF'
# Written by audio-reset.sh (ALSA mode).
# PipeWire/WirePlumber stay installed because the desktop needs them (screen
# sharing), but they must not open sound cards or Bluetooth audio, so ALSA
# programs get the hardware directly.
# To give audio back to PipeWire: delete this file and run audio-reset.sh --pipewire.
wireplumber.profiles = {
  main = {
    monitor.alsa = disabled
    monitor.alsa-midi = disabled
    monitor.bluez = disabled
    monitor.bluez-midi = disabled
  }
}
EOF
    good "WirePlumber: sound card and Bluetooth monitors disabled ($WP_ALSA_OFF)"
  fi
  if installed pipewire-pulse; then
    systemctl --global mask pipewire-pulse.socket pipewire-pulse.service
    good "pipewire-pulse masked (kept only because something depends on it)"
  fi
  if installed pulseaudio; then
    systemctl --global mask pulseaudio.socket pulseaudio.service
    mkdir -p /etc/pulse/client.conf.d
    printf '# Written by audio-reset.sh (ALSA mode)\nautospawn = no\n' >/etc/pulse/client.conf.d/90-audio-reset.conf
    good "PulseAudio masked and autospawn off (kept only because something depends on it)"
  fi
  if installed pipewire-alsa; then
    warn "pipewire-alsa is still installed (something needs it), so ALSA's default device"
    warn "still points at PipeWire. Programs must name the card (e.g. hw:0) to get sound."
  fi
  if installed pipewire; then
    systemctl --global enable pipewire.socket >/dev/null 2>&1 || true
  fi
  if installed wireplumber; then
    systemctl --global enable wireplumber.service >/dev/null 2>&1 || true
  fi

  msg "Installing ALSA"
  local -a install
  mapfile -t install < <(install_list "${ALSA_BASE[@]}" "${ALSA_FIRMWARE[@]}")
  pacman -S "${PAC_CONFIRM[@]}" "${install[@]}"
  refresh_installed
  choose_default_card
}

choose_default_card() {
  local -a cards
  local c num id desc pick=""
  mapfile -t cards < <(sed -nE 's/^ *([0-9]+) \[([^] ]+) *\]: (.*)$/\1|\2|\3/p' "$ASOUND/cards" 2>/dev/null || true)
  if (( ${#cards[@]} == 0 )); then
    warn "No sound cards found in $ASOUND/cards — check that your sound driver loads."
    return 0
  fi
  if (( ${#cards[@]} == 1 )) || (( ASSUME_YES )); then
    info "Default ALSA card: ${cards[0]##*|}"
    return 0
  fi
  msg "Pick your default sound card (where sound goes unless a program chooses)"
  for c in "${cards[@]}"; do
    IFS='|' read -r num id desc <<<"$c"
    printf '    %s) %s — %s\n' "$num" "$id" "$desc"
  done
  read -r -p "Card number [${cards[0]%%|*}]: " pick </dev/tty || pick=""
  pick=${pick:-${cards[0]%%|*}}
  if [[ ! $pick =~ ^[0-9]+$ ]] || [[ ! -e $ASOUND/card$pick ]]; then
    warn "No card $pick — leaving ALSA's default (card 0)."
    return 0
  fi
  cat >"$ASOUND_CONF" <<EOF
# Written by audio-reset.sh — default ALSA sound card.
# Card numbers can shift when USB audio is plugged in; check with: aplay -l
defaults.pcm.card $pick
defaults.ctl.card $pick
EOF
  good "Default card set to $pick ($ASOUND_CONF)"
}

# --------------------------------------------------------- restart/verify ---
restart_audio() {
  msg "Restarting audio for logged-in users"
  systemctl daemon-reload
  if (( ${#ACTIVE_USERS[@]} == 0 )); then
    info "Nobody is logged in — audio starts with the next login."
    return 0
  fi
  local u
  for u in "${ACTIVE_USERS[@]}"; do
    user_ctl "$u" daemon-reload || true
    user_ctl "$u" reset-failed >/dev/null 2>&1 || true
    if [[ $MODE == pipewire ]]; then
      user_ctl "$u" start pipewire.socket pipewire-pulse.socket pipewire.service wireplumber.service pipewire-pulse.service \
        || warn "$u: couldn't start PipeWire right now — it will start at next login."
    elif installed pipewire; then
      user_ctl "$u" start pipewire.socket pipewire.service >/dev/null 2>&1 || true
      if installed wireplumber; then user_ctl "$u" start wireplumber.service >/dev/null 2>&1 || true; fi
    fi
  done
  sleep 3
}

verify() {
  msg "Checking"
  local u server sinks
  if [[ $MODE == pipewire ]]; then
    for u in "${ACTIVE_USERS[@]}"; do
      server=$(user_run "$u" pactl info 2>/dev/null | sed -n 's/^Server Name: //p' || true)
      sinks=$(user_run "$u" pactl list short sinks 2>/dev/null | grep -vc 'auto_null' || true)
      if [[ $server == *PipeWire* ]]; then
        good "$u: $server — ${sinks:-0} output device(s)"
        if [[ ${sinks:-0} == 0 ]]; then
          warn "$u: no outputs yet. Run 'wpctl status' as $u; check the card shows up in 'aplay -l'."
        fi
      else
        warn "$u: PulseAudio API isn't answering yet (got: ${server:-nothing}). Log out and back in."
      fi
    done
  fi
  if command -v aplay >/dev/null 2>&1; then
    info "Sound cards ALSA sees:"
    aplay -l 2>/dev/null | grep '^card' | sed 's/^/      /' || info "  (none — is the driver loaded?)"
  fi
  if [[ $MODE == alsa ]] && [[ -n $(pgrep -x 'pulseaudio|pipewire-pulse' || true) ]]; then
    warn "A PulseAudio server is still running from before — a reboot clears it."
  fi
}

finish() {
  msg "${GRN}Done.${RST}${BOLD} ${MODE^^} mode"
  if [[ $MODE == pipewire ]]; then
    info "$(pacman -Q pipewire wireplumber 2>/dev/null | tr '\n' ' ')"
    info "Apps that were already playing may need restarting."
    info "Mixer: GNOME Settings → Sound, or 'wpctl status' in a terminal."
  else
    info "$(pacman -Q alsa-lib alsa-utils 2>/dev/null | tr '\n' ' ')"
    info "Mixer: alsamixer (M unmutes a channel). Test: speaker-test -c 2 -t wav -l 1"
    info "To switch back later: sudo bash audio-reset.sh --pipewire"
  fi
  info "Backups: $STATE_DIR/config-backup  and  ~/.audio-reset-backup-$TS"

  local want_reboot=0
  if (( AUTO_REBOOT )); then
    want_reboot=1
  elif [[ $MODE == alsa ]] && (( ! ASSUME_YES )) && ask "Reboot now? (recommended in ALSA mode, so the login screen lets go of the sound card too)" Y; then
    want_reboot=1
  fi
  if (( want_reboot )); then
    sync
    systemctl reboot
  fi
}

# ------------------------------------------------------------------- main ---
main() {
  preflight
  choose_mode
  print_plan

  if (( DRY_RUN )); then
    printf '\n'
    info "Dry run — nothing was changed.${MODE:+ (Use --alsa or --pipewire to preview the other mode.)}"
    exit 0
  fi

  printf '\n'
  if ! ask "Go ahead?" N; then
    info "Aborted — nothing was changed."
    exit 0
  fi

  save_state
  upgrade_system
  stop_audio
  purge_system_config
  purge_user_config
  if [[ $MODE == pipewire ]]; then pipewire_mode; else alsa_mode; fi
  restart_audio
  verify
  finish
}

main
