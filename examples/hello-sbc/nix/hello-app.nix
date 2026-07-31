# The application(s) this board runs, declared via sbc-deploy's generic
# app-service module. Everything project-specific lives here; the framework
# turns it into a hardened systemd unit + service user + firewall opening.
{ pkgs, ... }:
let
  # Placeholder "app": a trivial static HTTP server. Swap for a real package
  # (e.g. a Bazel-built binary exported from your own flake).
  hello = pkgs.writeShellScriptBin "hello-sbc" ''
    echo "hello-sbc is up on $(hostname)" >&2
    exec ${pkgs.python3}/bin/python3 -m http.server 8080
  '';
in
{
  services.sbcApps.hello = {
    description = "hello-sbc demo HTTP server";
    package = hello;
    exec = "bin/hello-sbc";
    ports = [ 8080 ];
    stateDirectory = "hello";
  };

  # Auto-connect to WiFi on boot (headless field use). Uncomment and set your
  # networks, most-preferred first (or set per-network `priority`). Passphrases
  # are baked into the image — see nix/modules/wifi.nix. To keep them out of your
  # repo, leave this commented and export $SBC_WIFI_SSID / $SBC_WIFI_PSK instead.
  # sbcDeploy.wifi.networks = [
  #   { ssid = "Home Wi-Fi";    psk = "hunter2"; priority = 100; }
  #   { ssid = "Phone Hotspot"; psk = "swordfish"; }
  # ];
}
