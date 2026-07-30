# OPTIONAL hardware module: enable hardware SPI (spidev) on the Raspberry Pi.
#
# Not imported by mkSbcSystem's defaults — opt in from a consumer's module list
# when the application drives SPI peripherals (e.g. SK9822/APA102 LEDs). Enables
# the SPI master in the device tree, ships spidev tooling, and grants an `spi`
# group access to /dev/spidev* so a non-root service user (member of `spi`) can
# open the bus. Hardware SPI0 is on the 40-pin header (MOSI=GPIO10, SCLK=GPIO11)
# on both Pi 4 (BCM2711) and Pi 5 (RP1).
{ config, lib, pkgs, ... }:
{
  # dtparam=spi=on. Set the LEAF directly — do NOT wrap the whole `{ all = …; }`
  # tree in lib.mkDefault: `hardware.raspberry-pi.config` is an attrset of
  # submodules, so a default-priority definition of the entire `all` subtree
  # loses to the upstream normal-priority `all` defaults (audio, vc4-kms-v3d, …)
  # and the `spi` leaf silently vanishes from the merged config.txt. Setting the
  # leaf lets it merge alongside the board defaults.
  hardware.raspberry-pi.config.all.base-dt-params.spi = {
    enable = true;
    value = "on";
  };

  # spidev_test / python spidev are handy for bring-up. `or null` guards against
  # nixpkgs revisions where the attr is absent.
  environment.systemPackages = with pkgs; [
    python3Packages.spidev or null
  ];

  users.groups.spi = { };
  users.groups.gpio = { };

  services.udev.extraRules = ''
    # Hardware SPI0. MOSI=GPIO10, SCLK=GPIO11.
    SUBSYSTEM=="spidev", KERNEL=="spidev0.0", GROUP="spi", MODE="0660"
    SUBSYSTEM=="spidev", KERNEL=="spidev0.1", GROUP="spi", MODE="0660"
    # GPIO access for sync/debug lines.
    SUBSYSTEM=="gpio", GROUP="gpio", MODE="0660"
  '';
}
