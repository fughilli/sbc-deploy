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
    nix # nix-store (closure size for the copy progress gauge)
    nixos-install-tools # nixos-install
    bashInteractive # the drop-to-a-shell fallback
  ];

  # The deploy public key, read at eval from the same env seam as the target's
  # ssh-deploy module ($SBC_DEPLOY_PUBKEY_FILE, exported by the deploy script's
  # cmd_image before the --impure build). Baking it into the LIVE installer means
  # you can SSH into the running installer from your workstation to watch/drive an
  # install — no console needed (see the AMD-GPU console saga). Empty when built
  # without keys; then the installer just has no authorized key (sshd still up).
  deployPubkeyFile = builtins.getEnv "SBC_DEPLOY_PUBKEY_FILE";
  deployKeys =
    lib.optional (deployPubkeyFile != "" && builtins.pathExists (/. + deployPubkeyFile))
      (lib.strings.trim (builtins.readFile (/. + deployPubkeyFile)));

  # The installer advertises itself over mDNS as <hostname>-installer.local, using
  # the same hostname the target will take (the --hostname override wins, else the
  # baked hostName) so it's predictable: `ssh root@amd-rig-installer.local`.
  hostnameOverride = builtins.getEnv "SBC_HOSTNAME_OVERRIDE";
  installerHostName =
    (if hostnameOverride != "" then hostnameOverride else hostName) + "-installer";

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

  # Remote access to the LIVE installer. The installation-cd already runs sshd;
  # bake the deploy key into root's authorized_keys so you can SSH in from your
  # workstation to watch/drive an install without touching the console — and open
  # port 22 (openssh.openFirewall) + advertise over mDNS so it's reachable by
  # name. PermitRootLogin defaults to prohibit-password, which permits key auth.
  services.openssh.enable = true;
  services.openssh.openFirewall = true;
  users.users.root.openssh.authorizedKeys.keys = deployKeys;
  networking.hostName = lib.mkForce installerHostName;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = { enable = true; addresses = true; workstation = true; };
  };

  # AMD (and some Intel) mini PCs garble the console when the GPU's KMS driver
  # takes over after stage-2 — the EFI framebuffer is fine, then amdgpu re-sets a
  # bad mode. nomodeset keeps the kernel on the EFI framebuffer, which renders
  # cleanly. The installer needs no GPU acceleration, so this is a safe default;
  # the installed system carries the same param (see nix/modules/x86-target.nix).
  boot.kernelParams = [ "nomodeset" ];

  # A recognisable artifact. mkForce beats installation-cd's mkImageMediaOverride.
  isoImage.isoName = lib.mkForce "sbc-install-${hostName}.iso";

  # Faster ISO assembly. mksquashfs compression of the on-ISO Nix store is the
  # long pole of the build and is purely CPU-bound — brutal under QEMU x86
  # emulation on an Apple-Silicon builder. The stock installation-cd default is a
  # high zstd level (small ISO, slow compress); drop to a fast level. This
  # installer is written to a USB and used once, so a modestly larger squashfs is
  # a good trade for a much faster (and far less emulation-punishing) build. Bump
  # the level back up if ISO size matters more than build time for you.
  isoImage.squashfsCompression = "zstd -Xcompression-level 3";

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
