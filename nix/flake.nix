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
      installerDir = ./installer;

      # The reusable modules, exposed both individually and as a bundle.
      sbcModules = {
        sbc-base = modulesDir + "/sbc-base.nix";
        ssh-deploy = modulesDir + "/ssh-deploy.nix";
        app-service = modulesDir + "/app-service.nix";
        identity = modulesDir + "/identity.nix";
        wifi = modulesDir + "/wifi.nix";
        spi = modulesDir + "/spi.nix";
      };

      # Build an SBC NixOS system. `family` selects the platform:
      #   * "raspberrypi" (default) — a nixos-raspberrypi system + SD image.
      #   * "x86_64"                — a stock nixpkgs x86_64-linux system
      #                               (UEFI/systemd-boot); its bootable installer
      #                               USB is built by mkInstallerIso / mkSbcProject.
      #   family       : "raspberrypi" | "x86_64". Overridden by $SBC_BOARD_FAMILY
      #                  (the sbc_application `board` attr's family). On x86_64 the
      #                  `board`/`boardModules`/cross RPi seams are unused.
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
        , family ? "raspberrypi"
        , modules ? [ ]
        , stateVersion ? "25.05"
        , buildPlatform ? null
        , leanImage ? false
        }:
        let
          # Super-lean seam. When on, strip the RPi sd-image's rescue toolkit
          # (profiles/base.nix: vim/testdisk/ddrescue/… + a broad filesystem set),
          # documentation, and NixOS's default extra packages — none of which a
          # headless appliance needs. Driven from Bazel via the sbc_application
          # `lean` attribute ($SBC_LEAN), or the `leanImage` arg for direct-Nix
          # consumers. Same getEnv-at-eval seam as board/hostname.
          envLean = builtins.getEnv "SBC_LEAN";
          resolvedLean = if envLean != "" then envLean == "1" else leanImage;
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

          # Generic build_data seam: the launcher exports SBC_BUILD_DATA as a
          # "basename=abspath;basename=abspath" manifest of Bazel-built files (see
          # the sbc_application `build_data` attr). Parse it (getEnv, --impure)
          # into an attrset keyed by basename and pass it to every appModule via
          # specialArgs as `sbcBuildData`. Empty {} in pure eval / when unset.
          envBuildData = builtins.getEnv "SBC_BUILD_DATA";
          sbcBuildData =
            if envBuildData == "" then { }
            else builtins.listToAttrs (map
              (entry:
                let
                  eq = nixpkgs.lib.splitString "=" entry;
                  key = builtins.head eq;
                  val = builtins.concatStringsSep "=" (builtins.tail eq);
                in
                { name = key; value = builtins.path { path = /. + val; name = key; }; })
              (nixpkgs.lib.filter (e: e != "")
                (nixpkgs.lib.splitString ";" envBuildData)));

          # Board "family" seam. The Bazel board definition carries a family
          # (raspberrypi | x86_64) on its 3rd line, exported as $SBC_BOARD_FAMILY
          # by launch.sh; it selects the system builder below. Empty (pure eval, or
          # older two-line board files) ⇒ raspberrypi, so the Pi path is unchanged.
          envFamily = builtins.getEnv "SBC_BOARD_FAMILY";
          resolvedFamily = if envFamily != "" then envFamily else family;

          specialArgs = inputs // { inherit self sbcBuildData; };

          # ---- modules shared by every family --------------------------------

          # Super-lean: no docs / NixOS manual and none of NixOS's default extra
          # packages (perl/rsync/strace) on a headless appliance.
          leanDocsModule = ({ lib, ... }: lib.mkIf resolvedLean {
            documentation.enable = lib.mkForce false;
            documentation.man.enable = lib.mkForce false;
            documentation.nixos.enable = lib.mkForce false;
            documentation.doc.enable = lib.mkForce false;
            documentation.info.enable = lib.mkForce false;
            environment.defaultPackages = lib.mkForce [ ];
          });

          # The board's IDENTITY. $SBC_HOSTNAME_OVERRIDE (read under `nix build
          # --impure`) wins over the baked-in hostName when non-empty. At
          # commissioning the deploy script's `--hostname` flag sets it; on a later
          # deploy_live the script instead sources it from the board's own
          # committed identity (/var/lib/sbc/hostname, written write-once by
          # identity.nix) — so a redeploy reuses the fixed identity and can never
          # reset it to the baked default. Same getEnv-at-eval seam as wifi.nix /
          # ssh-deploy.nix; empty (incl. pure eval) => hostName.
          hostIdentityModule = {
            networking.hostName =
              let override = builtins.getEnv "SBC_HOSTNAME_OVERRIDE";
              in if override != "" then override else hostName;
            system.stateVersion = stateVersion;
          };

          # Reusable sbc-deploy modules (always on; wifi is inert unless an SSID is
          # configured via sbcDeploy.wifi / $SBC_WIFI_SSID). sbc-base gates its RPi
          # wireless-firmware bits on aarch64, so it is safe on x86 too.
          commonModules = [
            sbcModules.sbc-base
            sbcModules.ssh-deploy
            sbcModules.app-service
            sbcModules.identity
            sbcModules.wifi
            leanDocsModule
            hostIdentityModule
          ];

          # ---- Raspberry Pi family (nixos-raspberrypi) -----------------------
          rpiModules = [
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

            # Super-lean: drop the RPi sd-image's profiles/base.nix — its only
            # config is a rescue toolkit (vim/testdisk/ddrescue/sshfs/tcpdump/…), a
            # broad supportedFilesystems set, and a ZFS hostId; none are wanted on
            # a headless ext4/vfat appliance (the ext4/vfat drivers come from the
            # mounts, not this profile). disabledModules is a top-level module key
            # that can't be gated by mkIf, so it reads resolvedLean directly.
            ({ modulesPath, ... }: {
              disabledModules =
                nixpkgs.lib.optional resolvedLean (modulesPath + "/profiles/base.nix");
            })

            # Cross-compilation: pin the build platform when requested (see the
            # cross seam above and the flake header). Inert (mkIf false) for a
            # native build, so the aarch64-on-aarch64 path is byte-for-byte
            # unchanged. Re-sources the kernel + RPi firmware from the (now
            # cross-capable) system pkgs — the board module otherwise takes them
            # from a native aarch64-linux package set that ignores buildPlatform.
            ({ lib, pkgs, ... }: lib.mkIf (resolvedBuildPlatform != null) {
              nixpkgs.buildPlatform = resolvedBuildPlatform;
              boot.kernelPackages = lib.mkForce pkgs.${kernelPackagesAttr};
              boot.loader.raspberry-pi.firmwarePackage = lib.mkForce pkgs.raspberrypifw;

              # systemd's BPF framework pulls Linux-only bpftool as a build-host
              # tool; drop it only when the build host isn't Linux (an
              # x86_64-linux -> aarch64-linux cross keeps it).
              nixpkgs.overlays = [
                (final: prev:
                  nixpkgs.lib.optionalAttrs (!prev.stdenv.buildPlatform.isLinux) {
                    systemd = prev.systemd.override { withLibBPF = false; };
                  })
              ];

              # Portable-but-`platforms=linux` build tools (e.g. yodl for zsh docs)
              # are refused up front on a non-Linux build host; downgrade to a
              # warning so the cross can proceed (genuinely Linux-bound tools are
              # disabled at the feature level above).
              nixpkgs.config.allowUnsupportedSystem =
                !(nixpkgs.lib.hasInfix "linux" resolvedBuildPlatform);
            })
          ];

          # ---- generic x86_64 (amd64) family ---------------------------------
          # A stock nixpkgs x86_64-linux system: UEFI/systemd-boot + by-label
          # root/boot filesystems (see x86-target.nix). This module is the x86
          # counterpart to the RPi board + sd-image modules above.
          x86Modules = [ (modulesDir + "/x86-target.nix") ];
        in
        if resolvedFamily == "x86_64"
        then
          # amd64 mini PC: no nixos-raspberrypi, no sd-image, no RPi cross module.
          # The bootable installer that carries this system's closure is built by
          # mkInstallerIso (see mkSbcProject).
          nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            inherit specialArgs;
            modules = x86Modules ++ commonModules ++ modules;
          }
        else
          nixos-raspberrypi.lib.nixosSystem {
            inherit specialArgs;
            modules = rpiModules ++ commonModules ++ modules;
          };

      # Build an interactive amd64 install USB (an ISO) that carries a target
      # x86_64-linux system and installs it onto a mini PC's internal disk.
      #   hostName       : the target's hostName (shown in the installer UI + the
      #                    ISO artifact name).
      #   targetToplevel : the target system's config.system.build.toplevel — the
      #                    WHOLE closure is baked into the ISO's nix store, so the
      #                    install is fully offline (no substituters/network).
      # The ISO is a stock nixpkgs installation-cd that auto-runs a small curses
      # installer on tty1 (nix/installer/sbc-install.sh via nix/installer/iso.nix):
      # it lets the operator pick the disk + see the layout, confirm, then
      # partitions (GPT: 512 MiB vfat ESP + ext4 root) and runs `nixos-install
      # --system <targetToplevel>`. Returns a nixosSystem; its
      # config.system.build.isoImage is the .iso.
      mkInstallerIso =
        { hostName
        , targetToplevel
        }:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = inputs // { inherit self targetToplevel hostName; };
          modules = [
            (nixpkgs + "/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix")
            (installerDir + "/iso.nix")
          ];
        };

      # Build the standard outputs for one SBC application, supporting all three
      # deployment modes (see the `sbc_application` Bazel macro):
      #   Raspberry Pi (family = "raspberrypi", default):
      #     * full system (base + app)    -> images.sdImage        (mode 1)
      #     * base system (net only)      -> images.sdImageBase    (mode 2)
      #   amd64 mini PC (family = "x86_64"):
      #     * full system installer USB   -> images.installerIso     (mode 1)
      #     * base system installer USB   -> images.installerIsoBase (mode 2)
      #   Both families:
      #     * full system for live switch -> nixosConfigurations.<hostName> (mode 3)
      # Consumers usually return this directly as their flake outputs.
      #   appModules    : the application — services.sbcApps + any system deps.
      #   systemModules : base config baked into BOTH images (wifi, hardware…),
      #                   so the base image can reach the network for deploy_live.
      #   family        : "raspberrypi" (default) or "x86_64"; selects the system
      #                   builder + which `images.*` are produced. Overridden by
      #                   $SBC_BOARD_FAMILY (the sbc_application `board` attr).
      #   buildPlatform : cross-compile on this platform instead of dispatching to
      #                   a native aarch64-linux builder (see mkSbcSystem); null
      #                   defers to the $SBC_CROSS / $SBC_BUILD_PLATFORM env seam.
      mkSbcProject =
        { hostName
        , board ? "raspberry-pi-5"
        , boardModules ? [ ]
        , family ? "raspberrypi"
        , appModules ? [ ]
        , systemModules ? [ ]
        , stateVersion ? "25.05"
        , buildPlatform ? null
        , leanImage ? false
        }:
        let
          mk = extra: mkSbcSystem {
            inherit hostName board boardModules family stateVersion buildPlatform leanImage;
            modules = systemModules ++ extra;
          };
          full = mk appModules;
          base = mk [ ];
          # Resolve the family the same way mkSbcSystem does (env over arg), so the
          # image outputs below match the branch the systems were actually built
          # for under `--impure`.
          envFamily = builtins.getEnv "SBC_BOARD_FAMILY";
          resolvedFamily = if envFamily != "" then envFamily else family;
        in
        {
          nixosConfigurations = {
            ${hostName} = full;
            "${hostName}-base" = base;
          };
          images =
            if resolvedFamily == "x86_64" then {
              # Bootable install USB (ISO), carrying the full/base target closure.
              installerIso =
                (mkInstallerIso {
                  inherit hostName;
                  targetToplevel = full.config.system.build.toplevel;
                }).config.system.build.isoImage;
              installerIsoBase =
                (mkInstallerIso {
                  inherit hostName;
                  targetToplevel = base.config.system.build.toplevel;
                }).config.system.build.isoImage;
            } else {
              sdImage = full.config.system.build.sdImage;
              sdImageBase = base.config.system.build.sdImage;
            };
        };
    in
    {
      lib = { inherit mkSbcSystem mkSbcProject; };

      nixosModules = sbcModules // {
        # `default` = the always-on bundle, for `imports = [ ...default ]`.
        default = { imports = [ sbcModules.sbc-base sbcModules.ssh-deploy sbcModules.app-service sbcModules.identity sbcModules.wifi ]; };
      };
    };
}
