{
  # sbc-deploy — a sized-up Linux builder VM for building SBC images on macOS.
  #
  # Apple-Silicon Macs can't build the aarch64-linux image locally, and the
  # stock `nix run nixpkgs#darwin.linux-builder` VM (3 GB RAM / 20 GB disk) OOMs
  # on the Raspberry Pi kernel compile. This is that same builder with more RAM,
  # disk, and cores, exposed as an app:
  #
  #   nix run 'github:fughilli/sbc-deploy?dir=nix/builder#linux-builder'
  #
  # IMPORTANT: it `.override`s the *packaged* `darwin.linux-builder`, layering
  # only memory/disk/cores. Those are runtime launch params (`-m`/`-smp` +
  # `$QEMU_OPTS`, and the disk is created at boot) — they do NOT change the guest
  # NixOS closure, so the guest stays byte-identical to the stock builder and is
  # served straight from cache.nixos.org. Only the small Darwin-side
  # create-builder script builds locally. That avoids the bootstrap trap you hit
  # by hand-rolling the VM: a from-scratch `nixosSystem` stamps the nixpkgs rev
  # into a *different*, uncached system derivation, which then needs an
  # aarch64-linux builder to realize — the very builder you're trying to create.
  #
  # It keeps upstream's default SSH key pair, host key, and port 31022, so the
  # one-time `/etc/nix/nix.conf` `builders` line and the ssh_config alias from
  # the README "Building on Apple Silicon" section apply unchanged.
  #
  # NOTE: darwin-only. The target Linux system is the host arch's linux twin, so
  # on Apple Silicon you get a native (un-emulated) aarch64-linux builder.

  description = "sbc-deploy — sized-up darwin.linux-builder VM for building SBC images on macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      darwinSystems = [ "aarch64-darwin" "x86_64-darwin" ];
      forDarwin = f: lib.genAttrs darwinSystems f;

      # Runtime-only sizing (does not change the cached guest closure). Bump if
      # a build still runs tight.
      sizeModule = {
        virtualisation.darwin-builder.memorySize = 8192; # MiB (default 3072)
        virtualisation.darwin-builder.diskSize = 40960; # MiB (default 20480)
        virtualisation.cores = 6;
      };

      installerFor = system:
        nixpkgs.legacyPackages.${system}.darwin.linux-builder.override {
          modules = [ sizeModule ];
        };
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
