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
  # NOTE: darwin-only. The default `linux-builder` target's Linux system is the
  # host arch's linux twin, so on Apple Silicon you get a native (un-emulated)
  # aarch64-linux builder. `linux-builder-x86` is an x86_64-linux variant (QEMU
  # emulation on Apple Silicon) for building amd64 images — see the comment on
  # `installerX86For` below.

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
        virtualisation.darwin-builder.diskSize = 61440; # MiB (default 20480) — RPi kernel build scratch is large
        virtualisation.cores = 6;
        # NOTE: we intentionally do NOT try to shrink a *persistent* builder disk
        # via qcow2 discard. discard=unmap on the drive is easy (darwin-side only),
        # but reclaiming needs an in-guest `fstrim`, and the stock darwin-builder
        # `builder` user has no root (no passwordless sudo; root ssh disabled).
        # Granting it — or mounting the store with continuous `discard`, or
        # enabling services.fstrim — all change the GUEST closure, which forfeits
        # the byte-identical cache-served guest above and re-triggers a from-source
        # guest build on every nixpkgs bump. Not worth it: the default builder disk
        # is ephemeral (deleted on stop, ~0 at rest), and the build *peak* is
        # reduced instead by trimming the target closure (see nix/modules).
      };

      installerFor = system:
        nixpkgs.legacyPackages.${system}.darwin.linux-builder.override {
          modules = [ sizeModule ];
        };

      # x86_64-linux builder variant, for building amd64 (x86_64-linux) images on
      # an Apple-Silicon Mac (family = "x86_64"; see nix/modules/x86-target.nix).
      # It's the SAME packaged darwin.linux-builder, but the guest system is
      # forced to x86_64-linux, so QEMU runs a full x86 guest under emulation and
      # the VM natively satisfies x86_64-linux builds — no per-derivation binfmt
      # juggling on the client side.
      #
      # Why this avoids a bootstrap build: the x86_64-linux guest closure has
      # `nixos.revision = null` (same as the native-twin builder), so it's
      # byte-identical to the guest Hydra builds for x86_64-darwin and is served
      # from cache.nixos.org. Only the small Darwin-side wrapper (create-builder /
      # run-builder, which launches qemu-system-x86_64) builds locally. Contrast
      # with adding `boot.binfmt.emulatedSystems` to the aarch64 guest: that
      # changes the aarch64 guest closure, making it uncached, so it would need an
      # aarch64-linux builder to realize — the very bootstrap trap this repo avoids.
      #
      # Trade-off: an x86 guest under QEMU TCG on Apple Silicon is un-accelerated,
      # so it boots slowly and computes slowly. For image builds that is fine —
      # the heavy userland substitutes prebuilt as x86_64 from the cache, and only
      # a handful of trivial per-config derivations (etc-*, unit-*.service,
      # configuration.nix, …) actually run on the VM.
      guestX86Module = { lib, ... }: {
        nixpkgs.hostPlatform = lib.mkForce "x86_64-linux";
      };
      installerX86For = system:
        nixpkgs.legacyPackages.${system}.darwin.linux-builder.override {
          modules = [ sizeModule guestX86Module ];
        };
    in
    {
      packages = forDarwin (system:
        let
          installer = installerFor system;
          installerX86 = installerX86For system;
        in {
          linux-builder = installer;
          linux-builder-x86 = installerX86;
          default = installer;
        });

      apps = forDarwin (system:
        let
          mkApp = installer: {
            type = "app";
            program = "${installer}/bin/create-builder";
          };
          app = mkApp (installerFor system);
        in {
          linux-builder = app;
          linux-builder-x86 = mkApp (installerX86For system);
          default = app;
        });
    };
}
