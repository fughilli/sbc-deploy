# Optional Tailscale membership for an SBC (opt-in; inert unless enabled).
#
# Enables tailscaled and opens its firewall port; the tailnet0 interface is
# trusted so tailnet peers can reach the board's services without per-port
# openings. The node's tailnet name is its hostname (networking.hostName — the
# board identity from identity.nix), so it appears as e.g. `amd-rig`.
#
# Auth is provisioned OUT OF BAND (never baked into the image / nix store), two
# ways:
#   * runtime — run `deploy/scripts/seed_tailscale.sh --host <h> --authkey tskey-…`
#     once; it does `tailscale up --authkey` over the deploy SSH (immediate), or
#   * declarative — set `sbcDeploy.tailscale.authKeyFile = "/var/lib/sbc/…"` and
#     drop the key at that path out of band; tailscaled auto-`tailscale up`s from
#     it on boot.
# tailscaled persists its node key under /var/lib/tailscale, so membership
# survives reboots and redeploys without re-seeding.
{ config, lib, ... }:
let
  cfg = config.sbcDeploy.tailscale;
in
{
  options.sbcDeploy.tailscale = {
    enable = lib.mkEnableOption "Tailscale (tailscaled) on this SBC";

    ssh = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Advertise Tailscale SSH from this node. Adds `--ssh` to the declarative
        authKeyFile bring-up; the seeder script takes its own `--ssh` flag.
      '';
    };

    authKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/sbc/tailscale.authkey";
      description = ''
        Path on the DEVICE to a Tailscale auth key file. When set, tailscaled
        auto-`tailscale up`s from it on boot. Seed the file out of band (never in
        git / the nix store). Leave null to bring the node up at runtime with
        deploy/scripts/seed_tailscale.sh instead.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      # Open the UDP port so peers can establish direct (non-relayed) connections.
      openFirewall = true;
      authKeyFile = lib.mkIf (cfg.authKeyFile != null) cfg.authKeyFile;
      extraUpFlags = lib.mkIf (cfg.authKeyFile != null && cfg.ssh) [ "--ssh" ];
    };

    # Reach the board's services (SSH, app ports) over the tailnet without opening
    # them to the LAN.
    networking.firewall.trustedInterfaces = [ "tailscale0" ];
  };
}
