{
  # sbc-deploy — a sized-up Linux builder VM for building SBC images on macOS.
  #
  # Apple-Silicon Macs can't build the aarch64-linux image locally, and the
  # stock `nix run nixpkgs#darwin.linux-builder` VM (~3 GB RAM) OOMs on the
  # Raspberry Pi kernel compile. This flake is that same builder with more RAM,
  # disk, and cores — enough to compile the kernel — exposed as an app:
  #
  #   nix run github:fughilli/sbc-deploy?dir=nix/builder#linux-builder
  #
  # It keeps the upstream builder's default SSH key pair, host key, and port
  # (31022), so the one-time `/etc/nix/nix.conf` `builders` line and the
  # `/etc/ssh/ssh_config.d/100-linux-builder.conf` alias from the README
  # "Building on Apple Silicon" section still apply unchanged. Only the VM size
  # differs. Leave the VM running in a terminal, then build with no --builder
  # flag (Nix routes aarch64-linux builds to it).
  #
  # NOTE: darwin-only. It can only be evaluated/run on macOS (aarch64-darwin or
  # x86_64-darwin); the target Linux system is the host arch's linux twin, so on
  # Apple Silicon you get a native (un-emulated) aarch64-linux builder.

  description = "sbc-deploy — sized-up darwin.linux-builder VM for building SBC images on macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      darwinSystems = [ "aarch64-darwin" "x86_64-darwin" ];
      forDarwin = f: lib.genAttrs darwinSystems f;

      # VM sizing. Bump these if a build still runs tight on RAM/disk.
      memorySize = 8192; # MiB — RPi kernel compile needs well over the ~3 GB default
      diskSize = 40960; # MiB — kernel build scratch + closure
      cores = 6;

      # Build the sized installer for one darwin host. The target Linux system is
      # the host arch's linux twin (aarch64-darwin -> aarch64-linux), so builds
      # run natively on Apple Silicon.
      installerFor = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          linuxSystem = lib.replaceStrings [ "darwin" ] [ "linux" ] system;
          builder = lib.nixosSystem {
            system = linuxSystem;
            modules = [
              "${nixpkgs}/nixos/modules/profiles/nix-builder-vm.nix"
              {
                virtualisation = {
                  host.pkgs = pkgs;
                  inherit cores;
                  darwin-builder = {
                    inherit memorySize diskSize;
                    workingDirectory = "/var/lib/darwin-builder";
                    # hostPort defaults to 31022 — matches the README ssh alias.
                  };
                };
              }
            ];
          };
        in
        builder.config.system.build.macos-builder-installer;
    in
    {
      packages = forDarwin (system:
        let installer = installerFor system; in {
          linux-builder = installer;
          default = installer;
        });

      apps = forDarwin (system:
        let
          app = {
            type = "app";
            program = "${installerFor system}/bin/create-builder";
          };
        in {
          linux-builder = app;
          default = app;
        });
    };
}
