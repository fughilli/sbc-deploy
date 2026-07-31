# The application(s) this board runs, declared via sbc-deploy's generic
# app-service module. Everything project-specific lives here; the framework
# turns it into a hardened systemd unit + service user + firewall opening.
{ config, pkgs, ... }:
let
  # Placeholder "app": a trivial static HTTP server. Swap for a real package
  # (e.g. a Bazel-built binary exported from your own flake). The hostname is
  # baked in at eval — the unit runs under ProtectSystem=strict with a minimal
  # PATH, so don't shell out to a `hostname` binary that isn't there.
  hello = pkgs.writeShellScriptBin "hello-sbc" ''
    echo "hello-sbc is up on ${config.networking.hostName}" >&2
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
}
