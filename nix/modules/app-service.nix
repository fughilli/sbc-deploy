# Generic "packaged application as a systemd service" module.
#
# The whole point of sbc-deploy: a consumer declares one or more applications
# under `services.sbcApps.<name>` and gets a hardened systemd unit, an optional
# dedicated service user, runtime/state dirs, and firewall openings — without
# hand-writing a unit per project. This replaces the project-specific units a
# bespoke image would otherwise carry.
#
# Example (in a consumer module):
#
#   services.sbcApps.web = {
#     description = "My web server";
#     package = self.packages.${pkgs.system}.web;   # a derivation…
#     exec = "bin/web --port 80";                    # …+ argv relative to it
#     ports = [ 80 ];
#     bindPrivilegedPorts = true;                    # grants CAP_NET_BIND_SERVICE
#     environment.MY_DB = "/var/lib/web/db";
#     stateDirectory = "web";                        # -> /var/lib/web
#   };
{ config, lib, pkgs, ... }:
let
  cfg = config.services.sbcApps;

  appModule = { name, config, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to run this application.";
      };
      description = lib.mkOption {
        type = lib.types.str;
        default = "sbc-deploy application: ${name}";
        description = "systemd unit description.";
      };
      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Application package. Combined with `exec` to form ExecStart.";
      };
      exec = lib.mkOption {
        type = lib.types.str;
        default = "bin/${name}";
        description = ''
          Command to run. If `package` is set this is interpreted relative to
          the package store path (e.g. "bin/foo --flag"); otherwise it must be
          an absolute command line.
        '';
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Dedicated system user the service runs as.";
      };
      createUser = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create the service user/group (disable to reuse an existing one).";
      };
      extraGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra groups for the service user (e.g. \"spi\", \"gpio\").";
      };
      ports = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        description = "TCP ports to open in the firewall for this app.";
      };
      bindPrivilegedPorts = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Grant CAP_NET_BIND_SERVICE so the app can bind ports < 1024 unprivileged.";
      };
      realtime = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run with FIFO real-time scheduling + CAP_SYS_NICE (e.g. tight SPI/GPIO timing).";
      };
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Environment variables for the service.";
      };
      after = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "network.target" ];
        description = "systemd After= dependencies.";
      };
      wants = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "systemd Wants= dependencies.";
      };
      runtimeDirectory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "RuntimeDirectory (under /run) for the service, if any.";
      };
      stateDirectory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "StateDirectory (under /var/lib) for the service, if any.";
      };
      readWritePaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra ReadWritePaths under the strict ProtectSystem sandbox.";
      };
      extraCapabilities = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra AmbientCapabilities beyond those implied by other options.";
      };
      extraServiceConfig = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Escape hatch: merged verbatim into serviceConfig.";
      };
    };
  };

  mkService = name: app:
    let
      execStart =
        if app.package != null
        then "${app.package}/${app.exec}"
        else app.exec;
      caps =
        (lib.optional app.bindPrivilegedPorts "CAP_NET_BIND_SERVICE")
        ++ (lib.optional app.realtime "CAP_SYS_NICE")
        ++ app.extraCapabilities;
    in
    lib.nameValuePair "sbc-${name}" {
      inherit (app) description;
      wantedBy = [ "multi-user.target" ];
      inherit (app) after wants;
      environment = app.environment;
      serviceConfig = {
        ExecStart = execStart;
        User = app.user;
        Restart = "on-failure";
        RestartSec = 2;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      }
      // lib.optionalAttrs (caps != [ ]) { AmbientCapabilities = caps; }
      // lib.optionalAttrs app.realtime {
        CPUSchedulingPolicy = "fifo";
        CPUSchedulingPriority = 50;
      }
      // lib.optionalAttrs (app.runtimeDirectory != null) {
        RuntimeDirectory = app.runtimeDirectory;
        RuntimeDirectoryMode = "0750";
      }
      // lib.optionalAttrs (app.stateDirectory != null) {
        StateDirectory = app.stateDirectory;
      }
      // lib.optionalAttrs (app.readWritePaths != [ ]) {
        ReadWritePaths = app.readWritePaths;
      }
      // app.extraServiceConfig;
    };

  enabledApps = lib.filterAttrs (_: app: app.enable) cfg;
in
{
  options.services.sbcApps = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule appModule);
    default = { };
    description = "Packaged applications to run on the board as systemd services.";
  };

  config = lib.mkIf (enabledApps != { }) {
    systemd.services = lib.mapAttrs' mkService enabledApps;

    users.users = lib.mkMerge (lib.mapAttrsToList
      (name: app: lib.optionalAttrs app.createUser {
        ${app.user} = {
          isSystemUser = true;
          group = app.user;
          description = "${app.description} (service user)";
          extraGroups = app.extraGroups;
        };
      })
      enabledApps);

    users.groups = lib.mkMerge (lib.mapAttrsToList
      (_: app: lib.optionalAttrs app.createUser { ${app.user} = { }; })
      enabledApps);

    networking.firewall.allowedTCPPorts =
      lib.concatMap (app: app.ports) (lib.attrValues enabledApps);
  };
}
