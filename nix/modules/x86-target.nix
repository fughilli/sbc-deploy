# Generic amd64 (x86_64-linux) appliance target.
#
# This is the x86 counterpart to a nixos-raspberrypi board module: it supplies
# the bootloader and the root/boot filesystems that the Pi's board + sd-image
# modules provide on the aarch64 side. Included only for `family = "x86_64"`
# systems (see mkSbcSystem).
#
# Boot: UEFI + systemd-boot, which virtually every current mini PC
# (Intel N100/N305, etc.) supports. Filesystems are addressed BY LABEL so the
# installed system boots regardless of the disk's device node (nvme0n1 vs sda) —
# the installer (nix/installer/sbc-install.sh) creates them with exactly these
# labels: an "ESP" vfat EFI partition and a "nixos" ext4 root.
{ lib, ... }:
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # Storage/USB controllers common to mini PCs, so the initrd can find the root
  # filesystem. Extend for a specific box if its NVMe/SATA HBA differs (a stock
  # `nixos-generate-config` on the target would list the exact set).
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ehci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
  ];

  # Many mini PCs (notably AMD Ryzen APUs) garble the console once the GPU's KMS
  # driver takes over after early boot — the EFI framebuffer renders fine, then
  # amdgpu re-sets a bad mode. nomodeset keeps the kernel on the EFI framebuffer.
  # A headless appliance needs no GPU acceleration, so this is a safe default and
  # guarantees a usable console if a monitor is ever attached. The installer ISO
  # carries the same param (see nix/installer/iso.nix). Drop it (or set an
  # explicit `video=` mode) if you later want KMS/GPU on this box.
  boot.kernelParams = [ "nomodeset" ];
}
