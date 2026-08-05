{
  # sbc-deploy — reusable Nix half of the SBC deployment framework.
  #
  # Provides:
  #   * lib.mkSbcSystem — build a Raspberry Pi NixOS system (+ SD image) from a
  #     board choice, hostname, and a list of consumer modules. Includes the
  #     generic sbc-base / ssh-deploy / app-service modules by default.
  #   * nixosModules.{sbc-base,ssh-deploy,app-service,spi,default} — the modules,
  #     for consumers who want to assemble a system themselves.
  #   * templates.default — a minimal starting-point flake (see examples/).
  #
  # All inputs are PINNED (see flake.lock). To bump: edit a ref here, run
  # `nix flake update` on a host with Nix, commit the lock.
  #
  # Board support comes from nvmd/nixos-raspberrypi. Building an image requires
  # an aarch64-linux builder (native or binfmt/qemu cross) and enough RAM/disk
  # for the RPi kernel compile when it is not served from a binary cache.

  description = "sbc-deploy — reusable Bazel + Nix framework for deploying apps to single-board computers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # Raspberry Pi board support (kernel, firmware, device tree, SD image).
    # Tag v1.20260517.0 == commit 06c6e3513e1ee64b651913193fc6ac38aa4963f5.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/v1.20260517.0";

    # Keep nixos-raspberrypi's nixpkgs aligned with ours for one coherent
    # package set (avoids a divergent kernel/firmware userspace).
    nixos-raspberrypi.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixos-raspberrypi, ... }@inputs:
    let
      modulesDir = ./modules;

      # The reusable modules, exposed both individually and as a bundle.
      sbcModules = {
        sbc-base = modulesDir + "/sbc-base.nix";
        ssh-deploy = modulesDir + "/ssh-deploy.nix";
        app-service = modulesDir + "/app-service.nix";
        wifi = modulesDir + "/wifi.nix";
        spi = modulesDir + "/spi.nix";
      };

      # Build a Raspberry Pi NixOS system.
      #   board       : "raspberry-pi-5" (default) or "raspberry-pi-4".
      #   hostName    : network hostname; also the default nixosConfigurations key.
      #   modules     : consumer NixOS modules (app definitions, extra hardware…).
      #   stateVersion: NixOS state version.
      mkSbcSystem =
        { hostName
        , board ? "raspberry-pi-5"
        , modules ? [ ]
        , stateVersion ? "25.05"
        }:
        nixos-raspberrypi.lib.nixosSystem {
          specialArgs = inputs // { inherit self; };
          modules = [
            ({ ... }: {
              imports = [
                nixos-raspberrypi.nixosModules.${board}.base
                nixos-raspberrypi.nixosModules.${board}.display-vc4
                # Provides config.system.build.sdImage.
                nixos-raspberrypi.nixosModules.sd-image
              ];
            })

            # Reusable sbc-deploy modules (always on; wifi is inert unless an
            # SSID is configured via sbcDeploy.wifi / $SBC_WIFI_SSID).
            sbcModules.sbc-base
            sbcModules.ssh-deploy
            sbcModules.app-service
            sbcModules.wifi

            {
              # Flash/deploy one config onto several boards without editing the
              # flake: $SBC_HOSTNAME_OVERRIDE (read under `nix build --impure`;
              # set by the deploy script's `--hostname` flag) wins over the
              # baked-in hostName when non-empty. Same getEnv-at-eval seam as
              # wifi.nix / ssh-deploy.nix; empty (incl. pure eval) => hostName.
              networking.hostName =
                let override = builtins.getEnv "SBC_HOSTNAME_OVERRIDE";
                in if override != "" then override else hostName;
              system.stateVersion = stateVersion;
            }
          ] ++ modules;
        };

      # Build the standard outputs for one SBC application, supporting all three
      # deployment modes (see the `sbc_application` Bazel macro):
      #   * full system (base + app)  -> images.sdImage      (mode 1)
      #   * base system (net only)    -> images.sdImageBase  (mode 2)
      #   * full system for live switch -> nixosConfigurations.<hostName> (mode 3)
      # Consumers usually return this directly as their flake outputs.
      #   appModules    : the application — services.sbcApps + any system deps.
      #   systemModules : base config baked into BOTH images (wifi, hardware…),
      #                   so the base image can reach the network for deploy_live.
      mkSbcProject =
        { hostName
        , board ? "raspberry-pi-5"
        , appModules ? [ ]
        , systemModules ? [ ]
        , stateVersion ? "25.05"
        }:
        let
          mk = extra: mkSbcSystem {
            inherit hostName board stateVersion;
            modules = systemModules ++ extra;
          };
          full = mk appModules;
          base = mk [ ];
        in
        {
          nixosConfigurations = {
            ${hostName} = full;
            "${hostName}-base" = base;
          };
          images = {
            sdImage = full.config.system.build.sdImage;
            sdImageBase = base.config.system.build.sdImage;
          };
        };
    in
    {
      lib = { inherit mkSbcSystem mkSbcProject; };

      nixosModules = sbcModules // {
        # `default` = the always-on bundle, for `imports = [ ...default ]`.
        default = { imports = [ sbcModules.sbc-base sbcModules.ssh-deploy sbcModules.app-service sbcModules.wifi ]; };
      };
    };
}
