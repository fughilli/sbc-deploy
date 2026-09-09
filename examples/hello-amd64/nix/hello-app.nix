# The application(s) this box runs, declared via sbc-deploy's generic
# app-service module — identical to the hello-sbc app; nothing here is
# architecture-specific. The framework turns it into a hardened systemd unit +
# service user + firewall opening.
{ config, pkgs, ... }:
let
  hello = pkgs.writeShellScriptBin "hello-amd64" ''
    echo "hello-amd64 is up on ${config.networking.hostName}" >&2
    exec ${pkgs.python3}/bin/python3 -m http.server 8080
  '';
in
{
  services.sbcApps.hello = {
    description = "hello-amd64 demo HTTP server";
    package = hello;
    exec = "bin/hello-amd64";
    ports = [ 8080 ];
    stateDirectory = "hello";
  };
}
