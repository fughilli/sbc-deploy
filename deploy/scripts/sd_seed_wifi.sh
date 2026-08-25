#!/usr/bin/env bash
# Offline sibling of seed_wifi.sh: add persistent WiFi networks to an ALREADY-IMAGED
# SD card, WITHOUT booting it or rebuilding the image. Writes the SAME
# `seed-<ssid>.nmconnection` NetworkManager keyfile that seed_wifi.sh's `nmcli`
# produces on a running board — into /etc/NetworkManager/system-connections on the
# card's ext4 ROOT partition. So it composes with the baked layer by
# autoconnect-priority (see nix/modules/wifi.nix) and is interchangeable with an
# online seed: `seed_wifi.sh --list/--remove` on the booted board sees these too.
#
# Uses e2fsprogs' `debugfs` to write into ext4 by device node — NO mount, and the
# profile is stored root:root 0600 regardless of who runs the tool. Cross-platform
# (Linux + macOS, where you can't mount ext4 at all — e2fsprogs IS available there,
# unlike e2tools). Raw block-device access needs privilege, so the tool re-execs
# debugfs under sudo when the device isn't writable; on macOS it first
# `diskutil unmountDisk`s the card so nothing holds the raw device.
#
#   sd_seed_wifi.sh --device /dev/sdX ( --ssid S --psk P [--priority N] [--hidden] \
#                                       | --file NETWORKS.yaml )
#   sd_seed_wifi.sh --device /dev/sdX --list
#   sd_seed_wifi.sh --device /dev/sdX --remove SSID
#   sd_seed_wifi.sh --root /mnt/sdroot ...      # write to an already-mounted root
#
# --device is the WHOLE-disk card (/dev/sdX, /dev/mmcblk0, /dev/disk4 on macOS); the
# tool finds the ext4 root partition itself. If auto-detection can't (unusual
# layout), point it straight at the partition with --partition /dev/sdX2.
#
# Leading arg (injected by the sh_binary): the runfiles path of a vendored debugfs.
# Kept bash-3.2-safe (runs under system bash).
set -uo pipefail

# --- begin runfiles.bash initialization v3 ---
f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null ||
  source "$0.runfiles/$f" 2>/dev/null ||
  { echo >&2 "ERROR: cannot find runfiles.bash"; exit 1; }
# --- end runfiles.bash initialization v3 ---

die() { echo "sd_seed_wifi: $*" >&2; exit 1; }

# Resolve the debugfs binary from the leading runfiles arg (its rlocationpath).
[ "$#" -ge 1 ] || die "internal: missing debugfs runfiles path (run via the bazel target)"
DEBUGFS="$(rlocation "$1")" || die "cannot resolve debugfs in runfiles ($1)"
[ -x "$DEBUGFS" ] || die "debugfs not executable ($DEBUGFS)"
shift

DEVICE="" PARTITION="" ROOT="" SSID="" PSK="" PRIORITY="" HIDDEN="no"
FILE="" ACTION="add" REMOVE_SSID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --device)    DEVICE="$2"; shift 2 ;;
    --partition) PARTITION="$2"; shift 2 ;;
    --root)      ROOT="$2"; shift 2 ;;
    --ssid)      SSID="$2"; shift 2 ;;
    --psk)       PSK="$2"; shift 2 ;;
    --priority)  PRIORITY="$2"; shift 2 ;;
    --hidden)    HIDDEN="yes"; shift ;;
    --file)      FILE="$2"; shift 2 ;;
    --list)      ACTION="list"; shift ;;
    --remove)    ACTION="remove"; REMOVE_SSID="$2"; shift 2 ;;
    -h|--help)   sed -n '2,33p' "$0"; exit 0 ;;
    *)           die "unknown arg: $1" ;;
  esac
done

NM_DIR="/etc/NetworkManager/system-connections"

# ---------------------------------------------------------------------------
# Target resolution: either an already-mounted --root, or an ext4 partition we
# drive with debugfs (found from --device, or given via --partition).
# ---------------------------------------------------------------------------
MODE=""            # "root" | "e2"
FS=""              # partition device node when MODE=e2
SUDO=""            # "sudo" prefix when the device isn't writable by this user

if [ -n "$ROOT" ]; then
  MODE="root"
  [ -d "$ROOT" ] || die "--root $ROOT is not a directory"
else
  [ -n "$DEVICE" ] || [ -n "$PARTITION" ] || die "give --device /dev/sdX (or --partition, or --root)"
  MODE="e2"
fi

pick_sudo() {
  # Raw block-device access usually needs privilege; probe writability once.
  if [ -w "$1" ]; then SUDO=""; else
    command -v sudo >/dev/null 2>&1 || die "no write access to $1 and sudo not found"
    SUDO="sudo"
  fi
}

# debugfs helpers. `ls -l /` lists entries on an ext fs and errors (empty stdout)
# on anything else, so it doubles as the ext probe and the /nix (NixOS root) test.
dbg_ls() { $SUDO "$DEBUGFS" -R "ls -l $2" "$1" 2>/dev/null; }
is_ext() { dbg_ls "$1" / | grep -q . ; }
has_nix() { dbg_ls "$1" / | grep -qw nix ; }

# On macOS, free the raw device: unmount the whole card (the FAT firmware partition
# auto-mounts; the ext4 one never does). No-op elsewhere.
mac_unmount() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  local disk="$1"
  disk="$(printf '%s' "$disk" | sed -E 's/s[0-9]+$//')"  # /dev/disk4s2 -> /dev/disk4
  $SUDO diskutil unmountDisk "$disk" >/dev/null 2>&1 || true
}

if [ "$MODE" = "e2" ]; then
  if [ -n "$PARTITION" ]; then
    FS="$PARTITION"; pick_sudo "$FS"; mac_unmount "$FS"
    is_ext "$FS" || die "$FS is not an ext filesystem (pass the ext4 ROOT partition)"
  else
    pick_sudo "$DEVICE"; mac_unmount "$DEVICE"
    # Candidate partition nodes by platform + base-name shape.
    base="$DEVICE"; sep=""
    case "$(uname -s)" in
      Darwin) sep="s" ;;                                          # /dev/disk4 -> /dev/disk4sN
      *) case "$base" in *[0-9]) sep="p" ;; *) sep="" ;; esac ;;  # mmcblk0p1 vs sda1
    esac
    FS=""; ext_hits=""
    for n in 1 2 3 4 5; do
      cand="${base}${sep}${n}"
      [ -e "$cand" ] || continue
      if is_ext "$cand"; then
        ext_hits="$ext_hits $cand"
        has_nix "$cand" && { FS="$cand"; break; }   # prefer the NixOS root (/nix)
      fi
    done
    if [ -z "$FS" ]; then
      set -- $ext_hits
      [ "$#" -eq 1 ] || die "could not identify the ext4 root on $DEVICE (candidates:${ext_hits:- none}); pass --partition /dev/…"
      FS="$1"
    fi
    echo "sd_seed_wifi: root partition -> $FS"
  fi
  # Refuse a currently-mounted partition (Linux); writing under a live mount
  # corrupts ext4. macOS never mounts ext4, and mac_unmount handled the card.
  if [ -r /proc/mounts ] && grep -q "^$FS " /proc/mounts; then
    die "$FS is mounted — unmount it first (writing under a live mount corrupts ext4)"
  fi
fi

# ---------------------------------------------------------------------------
# NetworkManager keyfile writers.
# ---------------------------------------------------------------------------
# A stable uuid per ssid (uuid5) makes re-seeding idempotent: NM keys on uuid, so
# the same ssid replaces in place rather than accumulating duplicates.
gen_uuid() { python3 -c 'import sys,uuid; print(uuid.uuid5(uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8"), "sbc-seed-"+sys.argv[1]))' "$1"; }

# Emit the keyfile — the shape nmcli writes for a wifi profile.
emit_profile() {
  local ssid="$1" psk="$2" prio="$3" hidden="$4"
  printf '[connection]\nid=seed-%s\nuuid=%s\ntype=wifi\nautoconnect-priority=%s\n\n' \
    "$ssid" "$(gen_uuid "$ssid")" "$prio"
  printf '[wifi]\nmode=infrastructure\nssid=%s\n' "$ssid"
  [ "$hidden" = "yes" ] && printf 'hidden=true\n'
  printf '\n'
  if [ -n "$psk" ]; then
    printf '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$psk"
  fi
  printf '[ipv4]\nmethod=auto\n\n[ipv6]\naddr-gen-mode=stable-privacy\nmethod=auto\n'
}

# write_profile: put the .nmconnection at $NM_DIR/seed-<ssid>.nmconnection, root:root 0600.
write_profile() {
  local ssid="$1" psk="$2" prio="${3:-50}" hidden="${4:-no}"
  [ -n "$ssid" ] || die "network missing ssid"
  local note=", open"; [ -n "$psk" ] && note=", wpa-psk"; [ "$hidden" = "yes" ] && note="$note, hidden"
  echo "  seeding '$ssid' (priority $prio$note)"
  local tmp; tmp="$(mktemp)"; emit_profile "$ssid" "$psk" "$prio" "$hidden" > "$tmp"
  local dest="$NM_DIR/seed-$ssid.nmconnection"
  if [ "$MODE" = "root" ]; then
    local d="$ROOT$NM_DIR"
    mkdir -p "$d" || { rm -f "$tmp"; die "mkdir $d failed (mount writable / run with privilege)"; }
    install -m 0600 "$tmp" "$ROOT$dest" || { rm -f "$tmp"; die "write $ROOT$dest failed"; }
    chown 0:0 "$ROOT$dest" 2>/dev/null || echo "    note: could not chown root:root (re-run privileged; NM ignores non-root keyfiles)" >&2
  else
    # One debugfs batch: create the dir chain (mkdir on an existing dir is a
    # non-fatal "File exists"), replace any prior file, write, and stamp
    # root:root 0600 (0100600 = regular file + rw-------).
    local cmds; cmds="$(mktemp)"
    {
      echo "mkdir /etc"
      echo "mkdir /etc/NetworkManager"
      echo "mkdir $NM_DIR"
      echo "rm $dest"
      echo "write $tmp $dest"
      echo "sif $dest mode 0100600"
      echo "sif $dest uid 0"
      echo "sif $dest gid 0"
    } > "$cmds"
    $SUDO "$DEBUGFS" -w -f "$cmds" "$FS" >/dev/null 2>&1
    rm -f "$cmds"
    # debugfs returns 0 even when individual requests fail, so verify the inode.
    dbg_stat "$dest" || { rm -f "$tmp"; die "debugfs write to $FS:$dest did not take"; }
  fi
  rm -f "$tmp"
  echo "    ok"
}

dbg_stat() { $SUDO "$DEBUGFS" -R "stat $1" "$FS" 2>/dev/null | grep -q "^Inode:"; }

list_seeds() {
  if [ "$MODE" = "root" ]; then ls -l "$ROOT$NM_DIR" 2>/dev/null | grep 'seed-' || echo "  (none)"
  else dbg_ls "$FS" "$NM_DIR" | grep 'seed-' || echo "  (none)"; fi
}

remove_seed() {
  local ssid="$1"; [ -n "$ssid" ] || die "--remove needs an SSID"
  local dest="$NM_DIR/seed-$ssid.nmconnection"
  if [ "$MODE" = "root" ]; then rm -f "$ROOT$dest"
  else $SUDO "$DEBUGFS" -w -R "rm $dest" "$FS" >/dev/null 2>&1 || true; fi
  echo "removed seed-$ssid"
}

# ---------------------------------------------------------------------------
case "$ACTION" in
  list)   echo "seeded WiFi profiles:"; list_seeds ;;
  remove) remove_seed "$REMOVE_SSID" ;;
  add)
    if [ -n "$FILE" ]; then
      [ -f "$FILE" ] || die "no such file: $FILE"
      echo "seeding networks from $FILE"
      # Same wifi.yaml schema + \x1f-delimited parse as seed_wifi.sh (an empty psk
      # for an open network mustn't collapse columns).
      python3 - "$FILE" <<'PY' | while IFS=$'\x1f' read -r ssid psk prio hidden; do
import sys
def minimal(text):
    nets, cur = [], None
    for raw in text.splitlines():
        line = raw.split('#', 1)[0].rstrip()
        if not line.strip():
            continue
        stripped = line.strip()
        if stripped.startswith('- '):
            if cur is not None: nets.append(cur)
            cur = {}
            stripped = stripped[2:].strip()
        if ':' in stripped and cur is not None:
            k, _, v = stripped.partition(':')
            cur[k.strip()] = v.strip().strip('"').strip("'")
    if cur: nets.append(cur)
    return nets
text = open(sys.argv[1]).read()
try:
    import yaml
    nets = yaml.safe_load(text) or []
except Exception:
    nets = minimal(text)
for n in nets:
    if not isinstance(n, dict) or not n.get('ssid'): continue
    hidden = 'yes' if str(n.get('hidden','')).lower() in ('true','yes','1') else 'no'
    print('\x1f'.join([str(n.get('ssid','')), str(n.get('psk','')),
                       str(n.get('priority','') or 50), hidden]))
PY
        write_profile "$ssid" "$psk" "$prio" "$hidden"
      done
    elif [ -n "$SSID" ]; then
      write_profile "$SSID" "$PSK" "${PRIORITY:-50}" "$HIDDEN"
    else
      die "give --ssid/--psk, --file, --list, or --remove"
    fi
    echo "done. profiles apply on the card's next boot (compose with the baked layer by priority)."
    ;;
esac
