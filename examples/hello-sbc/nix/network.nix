# System configuration baked into BOTH the base and full images (passed as a
# `systemModule` to mkSbcProject). Put networking + board hardware here so the
# base image can reach the network for `deploy_live`; the application itself
# goes in `appModules` (hello-app.nix).
{ ... }:
{
  # Auto-connect to WiFi on boot, most-preferred first (or per-network
  # `priority`). See the framework's nix/modules/wifi.nix. Passphrases are baked
  # into the image — to keep them out of the repo, leave this commented and
  # export $SBC_WIFI_SSID / $SBC_WIFI_PSK before building instead.
  # sbcDeploy.wifi.networks = [
  #   { ssid = "Home Wi-Fi";    psk = "hunter2"; priority = 100; }
  #   { ssid = "Phone Hotspot"; psk = "swordfish"; }
  # ];
}
