# The bootable amd64 install USB.
#
# Layered on top of nixpkgs' stock installation-cd-minimal (added by
# mkInstallerIso), this module:
#   * bakes the ENTIRE target closure into the ISO's nix store
#     (system.extraDependencies) so the install is fully offline — the mini PC
#     needs no network and no binary cache;
#   * ships a small curses installer (nix/installer/sbc-install.sh) that lets the
#     operator pick the target disk and see the partition layout, confirm, then
#     partitions + formats + runs `nixos-install --system <targetToplevel>`;
#   * auto-runs that installer on tty1. Other VTs keep the CD's autologin root
#     shell (Ctrl-Alt-F2) as an escape hatch; on cancel/failure the installer
#     drops to a shell instead of looping.
#
# `targetToplevel` and `hostName` arrive via specialArgs (see mkInstallerIso).
{ config, lib, pkgs, targetToplevel, hostName, ... }:
let
  # Everything the installer script shells out to. Baked into the script's PATH
  # (@path@) so it needs nothing from the ambient environment beyond systemd's
  # own tools (reboot/udevadm), which the appended $PATH still provides.
  installTools = with pkgs; [
    coreutils
    gnused
    gawk
    util-linux # lsblk, mount, umount, wipefs
    gptfdisk # sgdisk
    dosfstools # mkfs.vfat
    e2fsprogs # mkfs.ext4
    parted # partprobe
    newt # whiptail
    nixos-install-tools # nixos-install
    bashInteractive # the drop-to-a-shell fallback
  ];

  # The installer, with the build-time constants substituted in: the store path
  # of the baked target closure (@toplevel@), the target hostname (@host@), and
  # the tool PATH (@path@).
  sbcInstall = pkgs.writeShellScriptBin "sbc-install" (
    builtins.replaceStrings
      [ "@toplevel@" "@host@" "@path@" ]
      [ "${targetToplevel}" hostName (lib.makeBinPath installTools) ]
      (builtins.readFile ./sbc-install.sh)
  );
in
{
  # Force the whole target system closure into the ISO's nix store (and its DB),
  # so `nixos-install --system <targetToplevel>` runs without any substituter.
  system.extraDependencies = [ targetToplevel ];

  environment.systemPackages = [ sbcInstall ];

  # A recognisable artifact. mkForce beats installation-cd's mkImageMediaOverride.
  isoImage.isoName = lib.mkForce "sbc-install-${hostName}.iso";

  # Auto-run the installer on tty1.
  systemd.services.sbc-installer = {
    description = "sbc-deploy interactive installer";
    after = [ "systemd-user-sessions.service" "getty.target" ];
    wantedBy = [ "multi-user.target" ];
    # Take tty1 from the CD's autologin getty.
    conflicts = [ "getty@tty1.service" ];
    restartIfChanged = false;
    unitConfig.ConditionPathExists = "/dev/tty1";
    serviceConfig = {
      Type = "idle";
      ExecStart = "${sbcInstall}/bin/sbc-install";
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "journal";
      TTYPath = "/dev/tty1";
      TTYReset = true;
      TTYVHangup = true;
      # The script itself handles cancel/failure (drops to a shell); don't loop.
      Restart = "no";
    };
  };
}
