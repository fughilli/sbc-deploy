# sbc-deploy

A reusable **Bazel + Nix** framework for deploying packaged applications to
single-board computers (Raspberry Pi and friends).

You declare your application(s) once; sbc-deploy builds a bootable **NixOS
SD-card image** with each app wired up as a hardened systemd service, and gives
you push-button **image / live-deploy / key-management** targets. It was
extracted from the deploy tooling under `pi/` in
[`fughilli/splanc`](https://github.com/fughilli/splanc) so it can be reused
across projects, and will be vendored back into that repo once it's solid.

## How it's split

- **Nix half** (`nix/`) — a flake exposing `lib.mkSbcSystem` (build a Pi NixOS
  system + SD image from a board + hostname + your modules) and the reusable
  NixOS modules. Board support comes from
  [`nvmd/nixos-raspberrypi`](https://github.com/nvmd/nixos-raspberrypi).
- **Bazel half** (`deploy/`) — the `sbc_deploy` macro, which generates three
  runnable targets that shell out to `nix` / `nixos-rebuild`. The targets run
  under a **hermetic, nixpkgs-vendored bash** (imported via `rules_nixpkgs`), so
  the tool never depends on the host's system bash — which on macOS is the
  ancient 3.2. (Building a target therefore realizes that bash from Nix; since
  `nix` is required to do anything useful anyway, this costs nothing extra.)

## Using it in your project

**1. Add the Bazel dependency** (`MODULE.bazel`):

```starlark
bazel_dep(name = "sbc_deploy", version = "0.0.0")
git_override(
    module_name = "sbc_deploy",
    remote = "https://github.com/fughilli/sbc-deploy.git",
    commit = "…",
)
```

**2. Declare your app in a NixOS module** (`nix/myapp.nix`), using the generic
`services.sbcApps` option:

```nix
{ pkgs, ... }:
{
  services.sbcApps.web = {
    description = "My web server";
    package = pkgs.myWebServer;   # your derivation
    exec = "bin/web";             # argv, relative to the package
    ports = [ 80 ];               # opened in the firewall
    bindPrivilegedPorts = true;   # CAP_NET_BIND_SERVICE for :80
    stateDirectory = "web";       # -> /var/lib/web
  };
}
```

**3. Wire the flake** (`nix/flake.nix`):

```nix
{
  inputs.sbc-deploy.url = "github:fughilli/sbc-deploy?dir=nix";
  outputs = { self, sbc-deploy, ... }: {
    nixosConfigurations.myboard = sbc-deploy.lib.mkSbcSystem {
      hostName = "myboard";
      board = "raspberry-pi-5";        # or "raspberry-pi-4"
      modules = [ ./myapp.nix
                  sbc-deploy.nixosModules.spi ];  # opt-in hardware
    };
    images.sdImage =
      self.nixosConfigurations.myboard.config.system.build.sdImage;
  };
}
```

**4. Wire the Bazel targets** (`BUILD.bazel`):

```starlark
load("@sbc_deploy//deploy:defs.bzl", "sbc_deploy")

sbc_deploy(
    name = "myboard",
    flake = "path/to/nix",   # workspace-relative dir holding flake.nix
    hostname = "myboard",
)
```

## The three targets

```sh
# Generate the deploy SSH key pair (idempotent).
bazel run //path:myboard.keys        -- init

# Build the SD image; optionally flash it.
bazel run //path:myboard.image_sd    -- --no-write          # build + print path
bazel run //path:myboard.image_sd    -- --device /dev/sdX   # build + flash

# Upgrade a running board in place (nixos-rebuild switch --target-host).
bazel run //path:myboard.deploy_live -- myboard.local
```

Anything after a `--` is forwarded verbatim to `nix build` / `nixos-rebuild`
(e.g. `-- -- --dry-run`, or `--override-input` for local framework dev).

## SSH deploy key

The deploy flow owns one ed25519 key pair (see `keys` above):

- **public half** → baked into the image's root `authorized_keys` at build time
  (read at Nix eval from `$SBC_DEPLOY_PUBKEY_FILE`, which the targets export
  after generating the key), so a freshly imaged board trusts the deploy key on
  first boot — passwordless.
- **private half** → stays on the operator's machine, used by `deploy_live`.

Keys live in a gitignored `secrets/` dir alongside your flake (override with
`SBC_DEPLOY_KEY_DIR`). The private key is **never** committed and never enters
the Nix store (it lives outside the flake root; only the public half is read).
There is no password fallback — lose the private key and you re-image.

## What `mkSbcSystem` includes by default

- `sbc-base` — avahi/mDNS (`<hostName>.local`), firewall (SSH + mDNS; app ports
  added per-app), NetworkManager for field Wi-Fi. AP-mode is left as a
  documented seam.
- `ssh-deploy` — key-only sshd, deploy key trust, remote-rebuild toolchain.
- `app-service` — the `services.sbcApps.<name>` systemd generator (hardened
  units, dedicated service user, runtime/state dirs, firewall openings).

Opt-in extras (add to `modules`): `sbc-deploy.nixosModules.spi` (hardware SPI +
`spi`/`gpio` groups + udev, for SK9822/APA102-style peripherals).

## Requirements

- `bazel`/`bazelisk` (pinned 7.7.1) — for the targets.
- `nix` with flakes — required in all cases: building any deploy target realizes
  the hermetic bash from Nix, and the targets shell out to `nix` /
  `nixos-rebuild` to build an image or deploy.
- An `aarch64-linux` builder for image builds, with enough RAM/disk to compile
  the RPi kernel when it isn't cache-served. On a Linux host this is just the
  host itself; on macOS see below.

## Building on Apple Silicon (aarch64-darwin)

An SD image is a tree of `aarch64-linux` derivations, and Linux binaries can't
execute on macOS — so a Mac cannot build them locally. You'll see:

```
error: a 'aarch64-linux' with features {} is required to build '…', but I am a 'aarch64-darwin'
```

Cross-compiling the whole closure (Darwin → Linux) isn't practical — the binary
caches only have *native* `aarch64-linux`, so a cross build would rebuild the
world from source. Instead, dispatch the build to a **native `aarch64-linux`
builder**: same CPU arch, so it runs at full speed with full cache hits.

**Option A — local Linux builder VM (recommended; `nix-darwin`).** A background
NixOS VM that registers as an `aarch64-linux` builder:

```nix
# in your nix-darwin configuration
nix.linux-builder = {
  enable = true;
  maxJobs = 4;
  config.virtualisation = {
    cores = 6;
    darwin-builder.memorySize = 8 * 1024;   # MiB; ≥8 GB for the kernel compile
  };
};
nix.settings.trusted-users = [ "@admin" ];
```

Rebuild your Darwin system, then the targets work with **no extra flags**:

```sh
bazel run //examples/hello-sbc:hello.image_sd -- --no-write
```

**Option B — a remote `aarch64-linux` box** (a spare Linux server, another Pi,
etc.). Point a target at it with `--builder`, which takes a Nix `--builders`
spec — `ssh-ng://<user>@<host> <system> <ssh-key> <maxjobs> <speed> <features>`:

```sh
bazel run //examples/hello-sbc:hello.image_sd -- --no-write \
    --builder 'ssh-ng://you@linux-box aarch64-linux ~/.ssh/id_ed25519 8 1 big-parallel'
```

`--builder` forces all builds remote (`--max-jobs 0`) while both ends still
substitute from the binary cache. The host must be reachable over SSH, in your
`known_hosts`, and a Nix trusted user. Set `SBC_NIX_BUILDERS` to that spec to
make it the default without the flag; pass `--builder` more than once for
several builders.

**Kernel note:** the pinned Raspberry Pi kernel isn't in the binary cache for
this rev, so the builder compiles it once — give it ≥8 GB RAM and ~25 GB free.

For `deploy_live`, the same `--builder` applies; alternatively add
`-- --build-host <pi>` to build directly on the target board.

## Verification status

Verified in the sbc-deploy dev container (aarch64, Determinate Nix 3.21.8,
Bazel 7.7.1), 2026-07-30:

- **Bazel**: `bazel build //...` and `bazel query //...` clean; the
  `sbc_deploy` macro generates the three targets; `keys init/pub/path` run for
  real and write an ed25519 pair into the example's gitignored `secrets/`
  (confirmed absent from `git status` / `git check-ignore`).
- **Nix (framework)**: `nix flake metadata` on `nix/` resolves and the checked-in
  `flake.lock` is valid — all inputs (`nixpkgs 25.05`, `nixos-raspberrypi
  v1.20260517.0` + transitive `argononed`/`flake-compat`/`nixos-images`) lock
  cleanly.
- **Nix (example)**: the `hello-sbc` example locks against the framework and
  **begins evaluating** the full Pi NixOS system (`…config.system.build.sdImage`)
  with no expression errors, then **OOM-kills** during the `nixpkgs` fetch — the
  container has ~3.8 GB RAM, and a full `nixos-raspberrypi` eval needs more. This
  is a host-resource ceiling, not a code defect (the upstream `splanc` module
  documents the same limit; it evaluated and built to the kernel-compile step on
  an 8 GB aarch64 host).

**Not yet verified** (needs a bigger builder and/or real hardware): a complete
image build end-to-end, flashing, first boot on a real Pi, and a live
`deploy_live` switch. See `examples/hello-sbc/` for a runnable starting point.

## Layout

```text
sbc-deploy/
  MODULE.bazel                 # Bazel module (rules_shell only)
  deploy/
    defs.bzl                   # sbc_deploy macro (public API)
    scripts/launch.sh          # runfiles launcher: exec nix bash on the script
    scripts/sbc_deploy.sh      # generic image/deploy/keys entrypoint
  nix/
    flake.nix                  # lib.mkSbcSystem + nixosModules.*
    flake.lock                 # pinned inputs
    modules/
      sbc-base.nix             # networking / mDNS / firewall
      ssh-deploy.nix           # sshd + deploy-key trust
      app-service.nix          # services.sbcApps.<name> systemd generator
      spi.nix                  # opt-in hardware SPI
  examples/hello-sbc/          # minimal runnable consumer
```
