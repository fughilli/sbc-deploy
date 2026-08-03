# Optional WiFi auto-connect for headless field use.
#
# Declares one NetworkManager profile per network so the board joins on boot
# with no interaction. When several configured networks are in range,
# NetworkManager picks the highest priority. Inert unless at least one network
# is provided — via `sbcDeploy.wifi.networks` or the env vars
# $SBC_WIFI_SSID / $SBC_WIFI_PSK read at build time (the image/deploy targets
# build `--impure`, so exported vars reach eval; this keeps the passphrase out
# of your repo).
#
#   sbcDeploy.wifi.networks = [
#     { ssid = "Home Wi-Fi";    psk = "hunter2"; priority = 100; }
#     { ssid = "Phone Hotspot"; psk = "swordfish"; priority = 10; }
#     { ssid = "GuestOpen"; }   # open network, no psk
#   ];
#
# `priority` maps to NetworkManager's connection.autoconnect-priority (higher =
# preferred). Omit it and networks fall back to list order (earlier = higher).
#
# TWO COMPOSABLE LAYERS. NetworkManager loads profiles from two dirs, and this
# module + the seed tool use one each — they compose by autoconnect-priority and
# never clobber each other:
#   baked  — networks declared here → `ensureProfiles` writes them to *ephemeral*
#            /run/NetworkManager/system-connections and regenerates them from the
#            config on every boot. This is the always-there base set.
#   seeded — `deploy/scripts/seed_wifi.sh` (nmcli) writes to *persistent*
#            /etc/NetworkManager/system-connections, provisioned out of band and
#            never in git or the store. switch-to-configuration only rewrites
#            /run, so a redeploy NEVER clobbers seeded networks; add a network in
#            the field without a rebuild. Seeded profiles are named `seed-<ssid>`.
# Keep at least one reliable network in the baked layer so the board is always
# reachable even with an empty /etc.
#
# SECURITY: passphrases are written into the NixOS system closure, which lives
# in the world-readable /nix/store on the device (and in the image). Fine for a
# home/lab network on a hobby board; for real secret hygiene use NetworkManager's
# `ensureProfiles.environmentFiles` with a `$VAR` placeholder and provision the
# env file on the device out of band instead.
{ config, lib, ... }:
let
  cfg = config.sbcDeploy.wifi;

  networkOpts = { ... }: {
    options = {
      ssid = lib.mkOption {
        type = lib.types.str;
        description = "The network SSID to join.";
      };
      psk = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "WPA/WPA2 passphrase. Leave null for an open network.";
      };
      hidden = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the network does not broadcast its SSID.";
      };
      priority = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = ''
          autoconnect priority (higher is preferred when multiple configured
          networks are in range). Defaults to list order — earlier entries win.
        '';
      };
    };
  };

  # Declarative networks from a YAML file (converted to JSON in the Bazel graph;
  # see the sbc_application `wifi_config_file` arg). The env var holds an absolute
  # path to that JSON, read here at eval (`--impure`). Accepts a top-level list or
  # a `{ networks = [ … ]; }` object.
  cfgJsonPath = builtins.getEnv "SBC_WIFI_CONFIG_JSON";
  fileNetworks =
    if cfgJsonPath == "" then [ ]
    else
      let
        raw = builtins.fromJSON (builtins.readFile (/. + cfgJsonPath));
        list = if builtins.isList raw then raw else (raw.networks or [ ]);
      in
      map (n: {
        ssid = n.ssid;
        psk = n.psk or null;
        hidden = n.hidden or false;
        priority = n.priority or null;
      }) list;

  # A single network from $SBC_WIFI_SSID / $SBC_WIFI_PSK, if set — appended last
  # (lowest default priority) so explicit `networks` take precedence.
  envSsid = builtins.getEnv "SBC_WIFI_SSID";
  envPsk = builtins.getEnv "SBC_WIFI_PSK";
  envNetworks = lib.optional (envSsid != "") {
    ssid = envSsid;
    psk = if envPsk != "" then envPsk else null;
    hidden = false;
    priority = null;
  };

  networks = cfg.networks ++ fileNetworks ++ envNetworks;
  count = builtins.length networks;

  # Highest-priority = first in the list when `priority` is unset.
  mkProfile = i: net:
    let
      prio = if net.priority != null then net.priority else (count - i);
    in
    lib.nameValuePair "sbc-wifi-${toString i}" ({
      connection = {
        id = "sbc-wifi-${toString i}";
        type = "wifi";
        autoconnect-priority = toString prio;
      };
      wifi = {
        mode = "infrastructure";
        ssid = net.ssid;
      } // lib.optionalAttrs net.hidden { hidden = "true"; }
        // lib.optionalAttrs (cfg.band != null) { band = cfg.band; };
      ipv4.method = "auto";
      ipv6 = {
        addr-gen-mode = "stable-privacy";
        method = "auto";
      };
    } // lib.optionalAttrs (net.psk != null) {
      wifi-security = {
        key-mgmt = "wpa-psk";
        psk = net.psk;
      };
    });
in
{
  options.sbcDeploy.wifi.networks = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule networkOpts);
    default = [ ];
    description = ''
      WiFi networks to auto-connect to on boot, most-preferred first (or set
      per-network `priority`). A single network can also come from
      $SBC_WIFI_SSID / $SBC_WIFI_PSK at build time.
    '';
  };

  options.sbcDeploy.wifi.band = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum [ "bg" "a" ]);
    default = null;
    description = ''
      Lock STA association to a band — "bg" (2.4 GHz) or "a" (5 GHz) — via
      NetworkManager's `wifi.band`. Default null lets NM pick either. Set "bg"
      when the board must ALSO host a 2.4 GHz AP on the same radio: single-radio
      AP+STA is co-channel, so the uplink band dictates the AP's band, and a
      2.4 GHz-only client (e.g. an ESP32-C6) can only join a 2.4 GHz AP. NB: the
      chosen SSID must have a BSS on that band or the board won't associate.
    '';
  };

  config = lib.mkIf (networks != [ ]) {
    networking.networkmanager.ensureProfiles.profiles =
      lib.listToAttrs (lib.imap0 mkProfile networks);
  };
}
