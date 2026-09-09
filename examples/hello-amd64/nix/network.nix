# System configuration baked into BOTH the installer's target system and the
# live-deploy config (passed as a `systemModule` to mkSbcProject). An amd64 mini
# PC is usually wired, so this is empty by default — NetworkManager (enabled by
# the framework's sbc-base module) brings up DHCP on the ethernet port and the
# box is reachable at hello-amd64.local over mDNS for deploy_live.
{ ... }:
{
  # Optional WiFi auto-connect (same mechanism as the Pi). Uncomment to bake
  # networks in, or export $SBC_WIFI_SSID / $SBC_WIFI_PSK before building to keep
  # credentials out of the repo. See the framework's nix/modules/wifi.nix.
  # sbcDeploy.wifi.networks = [
  #   { ssid = "Home Wi-Fi"; psk = "hunter2"; priority = 100; }
  # ];

  # Join the tailnet. tailscaled is baked into the image; the auth key is seeded
  # at runtime (never in git / the store) after the box is up. Put a key in
  # secrets/tailscale-authkey, then:
  #   bazel run //examples/hello-amd64:hello.seed_tailscale -- amd-rig.local
  # The node appears on the tailnet as its hostname (e.g. amd-rig).
  sbcDeploy.tailscale.enable = true;
}
