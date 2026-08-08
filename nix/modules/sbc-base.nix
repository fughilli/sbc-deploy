# Baseline networking + zero-config discovery for an SBC deployment.
#
# Generic across projects: advertise the board over mDNS (avahi) as
# <hostName>.local so the deploy machine can reach it by name, open SSH + mDNS
# in the firewall, and use NetworkManager for field Wi-Fi. Application ports are
# opened by the app-service module, not here.
#
# AP-MODE SEAM: turning the board into its own access point
# (services.hostapd + services.dnsmasq) is intentionally left out of the default
# image — joining an existing network + mDNS is the simpler, predictable
# first-boot behaviour. Add a hostapd/dnsmasq module and import it to enable AP
# mode.
{ config, lib, pkgs, ... }:
let cfg = config.sbcDeploy;
in {
  options.sbcDeploy.leanFirmware = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Drop the generic linux-firmware blob (~700 MB of firmware for hardware a
      Raspberry Pi doesn't have) by disabling hardware.enableRedistributableFirmware.
      ON by default: the Pi's own Wi-Fi/Bluetooth firmware
      (raspberrypi-wireless-firmware) is a separate closure path and is kept, so
      Wi-Fi/Bluetooth should still work — but if a peripheral needs a generic
      blob, set this to false to include the full linux-firmware again.
    '';
  };

  config = {
  # Drop the generic firmware blob by default (see the option above)…
  hardware.enableRedistributableFirmware = lib.mkIf cfg.leanFirmware (lib.mkForce false);
  # …but the Pi's own Wi-Fi/Bluetooth firmware is pulled in via that same flag in
  # nixpkgs' all-firmware.nix, so it would vanish too. Add it back explicitly so
  # Wi-Fi/BT keep working without the 731 MB generic blob. (raspberrypi-firmware,
  # the bootloader/GPU firmware, comes from the board module and is unaffected.)
  hardware.firmware = lib.mkIf cfg.leanFirmware [ pkgs.raspberrypiWirelessFirmware ];

  # mDNS: advertise <hostName>.local and resolve *.local.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      domain = true;
      workstation = true;
    };
  };

  networking.firewall = {
    enable = lib.mkDefault true;
    allowedTCPPorts = [ 22 ];       # SSH (deploy); app ports added by app-service
    allowedUDPPorts = [ 5353 ];     # mDNS
  };

  # Field Wi-Fi via NetworkManager. Credentials are NOT baked into the image
  # (no secrets in the store); configure on first boot or pre-seed out of band.
  networking.networkmanager.enable = lib.mkDefault true;
  # Drop NixOS's default set of VPN plugins (openconnect, sstp, openvpn, l2tp,
  # vpnc, fortisslvpn, iodine). Their GUI variants drag ~0.5 GB of desktop cruft
  # into a headless image — webkitgtk, gtk3/4, gst-plugins, flite, freepats — none
  # of which a WiFi-only SBC needs. mkForce because the NM module sets a default
  # list. Consumers that genuinely need a VPN client can re-add the specific
  # plugin. (Basic WiFi uses wpa_supplicant, not these.)
  networking.networkmanager.plugins = lib.mkForce [ ];

  # The RPi sd-image's base profile enables a broad rescue-image filesystem set
  # (zfs, btrfs, xfs, ntfs, cifs, f2fs), each dragging its userland tools into
  # the image — zfs-user, btrfs-progs, cifs-utils (-> samba ~110 MB), ntfs-3g,
  # xfsprogs, f2fs-tools — plus kernel modules. A headless app SBC only ever
  # mounts its own vfat /boot + ext4 root, so drop the rest. mkForce beats the
  # base profile's defaults; a consumer that needs one back can re-enable it
  # (e.g. boot.supportedFilesystems.exfat = lib.mkOverride 40 true).
  boot.supportedFilesystems = {
    zfs = lib.mkForce false;
    btrfs = lib.mkForce false;
    xfs = lib.mkForce false;
    ntfs = lib.mkForce false;
    cifs = lib.mkForce false;
    f2fs = lib.mkForce false;
  };
  };
}
