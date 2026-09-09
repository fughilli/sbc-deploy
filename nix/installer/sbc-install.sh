#!/usr/bin/env bash
# sbc-deploy interactive installer — baked onto the amd64 install USB.
#
# Runs on tty1 of the installer ISO (see nix/installer/iso.nix). It:
#   1. lists the machine's disks and asks which to install onto (whiptail menu);
#   2. shows the exact partition layout + a final "this ERASES <disk>" confirm;
#   3. partitions (GPT: 512 MiB vfat ESP labelled ESP, ext4 root labelled nixos),
#      formats, mounts;
#   4. runs `nixos-install --system <baked closure>` — fully offline, since the
#      whole target closure is already in this ISO's nix store — then reboots.
#
# @toplevel@ / @host@ / @path@ are substituted at build time by iso.nix.
# NOTE: run under bash (writeShellScriptBin); we deliberately do NOT `set -e`
# because whiptail returns non-zero on Cancel/No and we handle those explicitly.
set -uo pipefail

# Hermetic PATH (sgdisk, mkfs.*, lsblk, whiptail, nixos-install, …). $PATH is
# appended so systemd's own tools (reboot, udevadm) still resolve.
export PATH="@path@:$PATH"

TOPLEVEL="@toplevel@"
TARGET_HOST="@host@"

BT="sbc-deploy installer — ${TARGET_HOST}"

# On error: explain, then drop to an interactive shell so the operator can
# investigate or re-run `sbc-install`. Never proceed past a failed step.
fail() {
  echo >&2
  echo "ERROR: $*" >&2
  echo >&2
  echo "Dropping to a shell. Re-run 'sbc-install' to try again, or 'reboot'." >&2
  exec bash
}

# Bail out to a shell on cancel (whiptail Cancel/No, Esc, etc.).
bail() {
  echo "${1:-Cancelled.}" >&2
  echo "Dropping to a shell. Re-run 'sbc-install' to start over, or 'reboot'." >&2
  exec bash
}

[ "$(id -u)" -eq 0 ] || fail "must run as root"
[ -e "$TOPLEVEL" ] || fail "baked system closure not found at $TOPLEVEL"

# --- 1. choose the target disk ------------------------------------------------
# One row per whole disk: NAME SIZE TYPE MODEL (MODEL may contain spaces, so it
# is the trailing field). Build a whiptail --menu of tag/description pairs.
menu_args=()
while read -r name size type model; do
  [ "$type" = "disk" ] || continue
  # Collapse an empty model to a placeholder so the description is never blank.
  [ -n "$model" ] || model="disk"
  menu_args+=("$name" "$size  $model")
done < <(lsblk -dpno NAME,SIZE,TYPE,MODEL)

[ "${#menu_args[@]}" -gt 0 ] || fail "no disks found (lsblk listed no TYPE=disk devices)"

DEV="$(whiptail --title "$BT" \
  --menu "Select the disk to install ${TARGET_HOST} onto.\n\nEVERYTHING on the chosen disk will be ERASED." \
  20 78 8 "${menu_args[@]}" 3>&1 1>&2 2>&3)" || bail "No disk selected."
[ -n "$DEV" ] || bail "No disk selected."
[ -b "$DEV" ] || fail "$DEV is not a block device"

# --- 2. show the layout + final confirmation ----------------------------------
current="$(lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DEV" 2>/dev/null || true)"
confirm_msg="Target disk: ${DEV}

New GPT partition layout:
  1  ESP    512 MiB  vfat  (label ESP,   -> /boot)
  2  nixos  rest     ext4  (label nixos, -> /)

Installing host: ${TARGET_HOST}

Current contents of ${DEV}:
${current}

This will DESTROY ALL DATA on ${DEV}. Continue?"

whiptail --title "Confirm ERASE of ${DEV}" --defaultno \
  --yesno "$confirm_msg" 24 78 || bail "Aborted — nothing was written."

# --- 3. partition, format, mount ----------------------------------------------
echo "==> Wiping and partitioning ${DEV}"
wipefs -a "$DEV" || true
sgdisk --zap-all "$DEV" || fail "sgdisk --zap-all failed on $DEV"
sgdisk -n1:0:+512M -t1:ef00 -c1:ESP "$DEV"   || fail "creating the ESP failed"
sgdisk -n2:0:0     -t2:8300 -c2:nixos "$DEV" || fail "creating the root partition failed"
partprobe "$DEV" 2>/dev/null || true
udevadm settle || true
sleep 2

# Resolve the partition device nodes (handles both sdX1 and nvmeXn1p1 naming).
mapfile -t parts < <(lsblk -rno NAME,TYPE "$DEV" | awk '$2=="part"{print "/dev/"$1}')
[ "${#parts[@]}" -ge 2 ] || fail "expected 2 partitions on $DEV, found ${#parts[@]}"
ESP="${parts[0]}"
ROOT="${parts[1]}"

echo "==> Formatting ${ESP} (ESP, vfat) and ${ROOT} (root, ext4)"
mkfs.vfat -F32 -n ESP "$ESP"    || fail "mkfs.vfat on $ESP failed"
mkfs.ext4 -F -L nixos "$ROOT"   || fail "mkfs.ext4 on $ROOT failed"
udevadm settle || true

echo "==> Mounting the new filesystems at /mnt"
mount "$ROOT" /mnt              || fail "mounting $ROOT at /mnt failed"
mkdir -p /mnt/boot
mount "$ESP" /mnt/boot          || fail "mounting $ESP at /mnt/boot failed"

# --- 4. install (offline) + reboot --------------------------------------------
echo "==> Installing NixOS from the baked closure (offline). This can take a few minutes…"
if ! nixos-install --system "$TOPLEVEL" --no-root-passwd --no-channel-copy --root /mnt; then
  umount -R /mnt 2>/dev/null || true
  fail "nixos-install failed"
fi

umount -R /mnt 2>/dev/null || true

whiptail --title "$BT" --msgbox \
  "Installation of ${TARGET_HOST} onto ${DEV} is complete.\n\nRemove the USB stick, then press OK to reboot into the installed system." \
  12 70 || true

echo "==> Rebooting…"
reboot
