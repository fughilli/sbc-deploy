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
  #
  # CROSS-BUILDING. Instead of dispatching to a native aarch64-linux builder,
  # the host can cross-compile the aarch64-linux closure directly (so macOS and
  # x86_64-linux need no builder VM/box). hostPlatform stays aarch64-linux (set
  # by the board module); mkSbcSystem pins nixpkgs.buildPlatform to the build
  # machine, which flips nixpkgs into cross mode, AND re-sources the RPi kernel +
  # firmware from the (now cross-capable) system pkgs — the board module
  # otherwise takes them from nixos-raspberrypi.packages.<system>, a native
  # aarch64-linux package set that ignores buildPlatform and would still require
  # an aarch64-linux builder (see the cross-kernel override in mkSbcSystem). Opt
  # in with the `buildPlatform` arg, or the $SBC_CROSS / $SBC_BUILD_PLATFORM env
  # seam the deploy script's `--cross` flag drives. Trade-off: the binary caches
  # only hold *native* aarch64-linux, so a cross build has no cache hits and
  # rebuilds from source (including the RPi kernel) — see the README "Building on
  # Apple Silicon".

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
      #   board        : nixos-raspberrypi board, e.g. "raspberry-pi-5" (default),
      #                  "raspberry-pi-4", "raspberry-pi-3", "raspberry-pi-02".
      #                  Overridden by $SBC_BOARD (the sbc_application `board` attr).
      #   boardModules : optional nixos-raspberrypi board submodules to import,
      #                  e.g. [ "display-vc4" ]. Overridden by $SBC_BOARD_MODULES.
      #   hostName     : network hostname; also the default nixosConfigurations key.
      #   modules      : consumer NixOS modules (app definitions, extra hardware…).
      #   stateVersion : NixOS state version.
      #   buildPlatform: when non-null, cross-compile the (aarch64-linux) system
      #                  on this build platform (e.g. "aarch64-darwin" or
      #                  "x86_64-linux") instead of building it natively /
      #                  dispatching to a remote aarch64-linux builder. Overrides
      #                  the $SBC_CROSS / $SBC_BUILD_PLATFORM env seam below.
      mkSbcSystem =
        { hostName
        , board ? "raspberry-pi-5"
        , boardModules ? [ ]
        , modules ? [ ]
        , stateVersion ? "25.05"
        , buildPlatform ? null
        }:
        let
          # Board seam. The board and its optional nixos-raspberrypi submodules
          # can be selected from Bazel via the sbc_application `board` attribute
          # (a board-definition target), which bakes $SBC_BOARD /
          # $SBC_BOARD_MODULES — read here under `--impure`, same getEnv-at-eval
          # seam as hostname/wifi. An explicit `board`/`boardModules` arg is the
          # fallback for consumers assembling a system directly in Nix.
          envBoard = builtins.getEnv "SBC_BOARD";
          resolvedBoard = if envBoard != "" then envBoard else board;
          envBoardModules = builtins.getEnv "SBC_BOARD_MODULES";
          resolvedBoardModules =
            if envBoardModules != ""
            then nixpkgs.lib.filter (m: m != "") (nixpkgs.lib.splitString "," envBoardModules)
            else boardModules;
          # Cross seam. hostPlatform is fixed to aarch64-linux by the board
          # module; setting nixpkgs.buildPlatform to a *different* platform flips
          # nixpkgs into cross-compilation, so the host realizes the closure
          # itself. Resolution (first non-empty wins): the explicit buildPlatform
          # arg, then $SBC_BUILD_PLATFORM (an explicit platform string), then
          # $SBC_CROSS (any non-empty value) => the host's builtins.currentSystem.
          # Env vars use the same getEnv-at-eval seam as hostname/wifi/pubkey and
          # are read only under `--impure`; in pure eval they are "" and this
          # stays inert (native aarch64-on-aarch64 build, today's behaviour).
          envBuildPlatform = builtins.getEnv "SBC_BUILD_PLATFORM";
          envCross = builtins.getEnv "SBC_CROSS";
          resolvedBuildPlatform =
            if buildPlatform != null then buildPlatform
            else if envBuildPlatform != "" then envBuildPlatform
            else if envCross != "" then builtins.currentSystem
            else null;

          # The cross-capable kernel attr the nixos-raspberrypi kernel-and-firmware
          # overlay exposes on the system `pkgs`, derived from the board name:
          # "raspberry-pi-5" -> "linuxPackages_rpi5", "…-02" -> "linuxPackages_rpi02".
          # See the cross-kernel override in the module list below.
          kernelPackagesAttr =
            "linuxPackages_rpi" + nixpkgs.lib.removePrefix "raspberry-pi-" resolvedBoard;
        in
        nixos-raspberrypi.lib.nixosSystem {
          specialArgs = inputs // { inherit self; };
          modules = [
            ({ ... }: {
              imports = [
                nixos-raspberrypi.nixosModules.${resolvedBoard}.base
                # Provides config.system.build.sdImage.
                nixos-raspberrypi.nixosModules.sd-image
              ]
              # Optional board submodules (display-vc4, bluetooth, …) chosen by the
              # board definition. Filtered to those the board actually provides, so
              # a board that lacks one (the Pi 3 has no display-vc4, for instance)
              # still evaluates instead of erroring on a missing attr.
              ++ nixpkgs.lib.filter (m: m != null)
                   (map (m: nixos-raspberrypi.nixosModules.${resolvedBoard}.${m} or null)
                        resolvedBoardModules);
            })

            # Cross-compilation: pin the build platform when requested (see the
            # cross seam above). Inert (mkIf false) for a native build, so the
            # aarch64-on-aarch64 path is byte-for-byte unchanged.
            ({ lib, pkgs, ... }: lib.mkIf (resolvedBuildPlatform != null) {
              # hostPlatform stays aarch64-linux (board module); pinning
              # buildPlatform to a *different* platform flips nixpkgs into cross
              # mode so this host realizes the closure.
              nixpkgs.buildPlatform = resolvedBuildPlatform;

              # Re-source the kernel + RPi firmware from the system's own (now
              # cross-capable) pkgs. The board module defaults BOTH to
              # nixos-raspberrypi.packages.<system>.* — a *native* aarch64-linux
              # instantiation (`import nixpkgs { system = "aarch64-linux"; }`) that
              # ignores nixpkgs.buildPlatform, so it always demands an
              # aarch64-linux builder and defeats --cross (the kernel + firmware
              # are the very things cross-building has to produce locally). The
              # kernel-and-firmware overlay already exposes the same attrs on the
              # system pkgs: pkgs.linuxPackages_rpiN builds via `buildLinux`, which
              # honours stdenv.hostPlatform and cross-compiles, and
              # pkgs.raspberrypifw is prebuilt firmware (a plain unpack that now
              # runs on the build platform instead of needing an aarch64-linux one).
              # mkForce beats the board module's mkDefault. This whole module is
              # inert for a native build, so cached native artifacts are unaffected.
              boot.kernelPackages = lib.mkForce pkgs.${kernelPackagesAttr};
              boot.loader.raspberry-pi.firmwarePackage = lib.mkForce pkgs.raspberrypifw;

              # systemd's BPF framework (withLibBPF) compiles its BPF programs at
              # build time, pulling bpftool + clang/llvm as *build-host*
              # (nativeBuildInputs) tools. Those are Linux-only, so a non-Linux
              # build host (macOS) can't provide them and cross eval dies on
              # `bpftools … not available on hostPlatform "…-darwin"`. Disable the
              # framework, but ONLY when the build host isn't Linux — an
              # x86_64-linux -> aarch64-linux cross keeps it (bpftool runs there).
              # The overlay gates itself on buildPlatform, so it's a no-op for a
              # Linux builder even though this module is active.
              nixpkgs.overlays = [
                (final: prev:
                  nixpkgs.lib.optionalAttrs (!prev.stdenv.buildPlatform.isLinux) {
                    systemd = prev.systemd.override { withLibBPF = false; };
                  })
              ];

              # Many build-time helpers (e.g. yodl, used to render zsh's man
              # pages) are perfectly portable but nixpkgs marks them
              # `platforms = linux`, so cross eval from a non-Linux host is
              # *refused* before they even get a chance to compile. Downgrade that
              # refusal to a warning so those tools build for the Darwin build
              # host and the cross can proceed. Only genuinely Linux-bound tools
              # (which we disable at the feature level, e.g. systemd's bpftool
              # above) would then fail later at build time, which is the correct
              # signal. Scoped to a non-Linux build host; a Linux builder keeps the
              # strict default. (resolvedBuildPlatform is non-null here.)
              nixpkgs.config.allowUnsupportedSystem =
                !(nixpkgs.lib.hasInfix "linux" resolvedBuildPlatform);
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
      #   buildPlatform : cross-compile on this platform instead of dispatching to
      #                   a native aarch64-linux builder (see mkSbcSystem); null
      #                   defers to the $SBC_CROSS / $SBC_BUILD_PLATFORM env seam.
      mkSbcProject =
        { hostName
        , board ? "raspberry-pi-5"
        , boardModules ? [ ]
        , appModules ? [ ]
        , systemModules ? [ ]
        , stateVersion ? "25.05"
        , buildPlatform ? null
        }:
        let
          mk = extra: mkSbcSystem {
            inherit hostName board boardModules stateVersion buildPlatform;
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
