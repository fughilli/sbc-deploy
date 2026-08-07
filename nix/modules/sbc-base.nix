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
  options.sbcDeploy.leanFirmware = lib.mkEnableOption ''
    dropping the generic linux-firmware blob (~700 MB of firmware for hardware a
    Raspberry Pi doesn't have). The Pi's own Wi-Fi/Bluetooth firmware
    (raspberrypi-wireless-firmware) is provided separately and is kept, so Wi-Fi
    should still work — but this disables hardware.enableRedistributableFirmware,
    so verify Wi-Fi/Bluetooth on your actual board before relying on it
  '';

  config = {
  # Trim the generic firmware blob when opted in (see the option above).
  hardware.enableRedistributableFirmware = lib.mkIf cfg.leanFirmware (lib.mkForce false);

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
  };
}
