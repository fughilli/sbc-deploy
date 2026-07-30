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
{
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
}
