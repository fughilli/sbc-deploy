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
- **Bazel half** (`deploy/`) — the `sbc_application` macro, which generates the
  runnable targets; they drive `nix` (build, `nix copy`, and activate over SSH).
  The targets run
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

**3. Wire the flake** (`nix/flake.nix`) with `mkSbcProject`. It splits your
config into `appModules` (the application, in the full image only) and
`systemModules` (networking/hardware, baked into both images so the base image
is reachable), and returns the outputs for all three modes:

```nix
{
  inputs.sbc-deploy.url = "github:fughilli/sbc-deploy?dir=nix";
  outputs = { self, sbc-deploy, ... }:
    sbc-deploy.lib.mkSbcProject {
      hostName = "myboard";
      board = "raspberry-pi-5";               # or "raspberry-pi-4"
      appModules = [ ./myapp.nix ];           # your application
      systemModules = [ ./network.nix         # wifi etc. (both images)
                        sbc-deploy.nixosModules.spi ];  # opt-in hardware
    };
}
```

**4. Wire the Bazel targets** (`BUILD.bazel`):

```starlark
load("@sbc_deploy//deploy:defs.bzl", "sbc_application")

sbc_application(
    name = "myboard",
    flake = "path/to/nix",   # workspace-relative dir holding flake.nix
    hostname = "myboard",
    # If sbc-deploy's own nix/ lives in this repo (in-repo or vendored in-tree),
    # point at it — the targets then build against that in-tree framework via
    # --override-input, so Bazel is the single version pin (no `nix flake
    # update`). Omit for external bazel_dep consumers, who pin via their flake.
    # framework = "third_party/sbc-deploy/nix",
)
```

Once `framework` is set, the deploy targets are fully self-contained: they inject
that framework into every build (image and deploy), so bumping the framework is
a single Bazel pin — you never run `nix flake update` for it.

## Deployment modes

`sbc_application` generates a target per mode (plus `keys`):

```sh
# Generate the deploy SSH key pair (idempotent, once per project).
bazel run //path:myboard.keys          -- init

# Mode 1 — full system image: minimal system + your bundled application.
bazel run //path:myboard.image_sd      -- --no-write          # build + print path
bazel run //path:myboard.image_sd      -- --device /dev/sdX   # build + flash

# Mode 2 — base system image only: networking/hardware config, no application.
# Flash this once to provision a board, then push apps to it with deploy_live.
bazel run //path:myboard.image_sd_base -- --device /dev/sdX

# Mode 3 — push the application (and any required system deps) to a running
# board in place: build the closure, nix-copy it over, switch-to-configuration.
bazel run //path:myboard.deploy_live   -- myboard.local

# Convenience — ssh in with the deploy key (defaults to <hostname>.local):
bazel run //path:myboard.ssh                            # -> root@myboard.local
bazel run //path:myboard.ssh -- 192.168.1.42           # explicit host/IP
bazel run //path:myboard.ssh -- -- systemctl status sbc-web   # run a remote command
```

| Mode | Target | What it deploys |
| ---- | ------ | --------------- |
| 1 | `image_sd` | Full SD image — base system **+** bundled app |
| 2 | `image_sd_base` | SD image of the base system only (networking) |
| 3 | `deploy_live` | App + its system deps onto a running board, no reflash |

Anything after a `--` is forwarded verbatim to the underlying `nix build`
(e.g. `-- -- --dry-run`, `--builder …`, or `--override-input` for local dev).

### Flashing the SD card

Pass `--device` to write the built image to a card. The target handles both
Linux and macOS, decompresses the `.img.zst` on the fly (bundled `zstd`), shows
a progress bar / ETA (bundled `pv`), and asks you to re-type the device path to
confirm before overwriting.

```sh
# Linux — find the card (e.g. /dev/sdX), then:
lsblk
bazel run //path:myboard.image_sd -- --device /dev/sdX

# macOS — find the disk id, then pass /dev/diskN (it uses the raw node + diskutil
# to unmount/eject):
diskutil list
bazel run //path:myboard.image_sd -- --device /dev/disk4
```

The write runs under `sudo` (you'll be prompted). Double-check the device — this
overwrites the whole disk. On macOS the first build/flash pulls `zstd` from the
cache (tiny).

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
- `wifi` — optional auto-connect: inline `sbcDeploy.wifi.networks`, a declarative
  `wifi_config_file` (YAML), or env vars; see "WiFi auto-connect" below.

Opt-in extras (add to `modules`): `sbc-deploy.nixosModules.spi` (hardware SPI +
`spi`/`gpio` groups + udev, for SK9822/APA102-style peripherals).

## WiFi auto-connect

For a headless board, declare one or more networks and it joins on boot (one
NetworkManager profile each, `wifi.nix` — always on, inert until you add a
network). When several are in range, the highest priority wins. In any module
of your config:

```nix
{
  sbcDeploy.wifi.networks = [
    { ssid = "Home Wi-Fi";    psk = "hunter2";   priority = 100; }
    { ssid = "Phone Hotspot"; psk = "swordfish"; priority = 10; }
    { ssid = "GuestOpen"; }   # open network (no psk)
    # { ssid = "Hidden"; psk = "…"; hidden = true; }
  ];
}
```

`priority` maps to NetworkManager's `autoconnect-priority` (higher = preferred).
Omit it and networks fall back to **list order** — earlier entries win.

### As a declarative YAML file

Instead of inline Nix, point the `sbc_application` macro at a single YAML file
(`wifi_config_file`) — a list of networks, converted to JSON in the Bazel graph
and baked in (no manual nix step, nothing to keep in sync):

```starlark
sbc_application(
    name = "myboard",
    flake = "path/to/nix",
    framework = "nix",
    wifi_config_file = "wifi.yaml",   # a label in this package
)
```

```yaml
# wifi.yaml — most-preferred first, or set an explicit `priority`.
- ssid: Home Wi-Fi
  psk: hunter2
  priority: 100
- ssid: Phone Hotspot
  psk: swordfish
- ssid: GuestOpen          # open network — omit psk
# - { ssid: Hidden, psk: "…", hidden: true }
```

File networks merge with any inline `sbcDeploy.wifi.networks`. Keep a real
`wifi.yaml` out of git (e.g. `.gitignore` it) if it holds live passphrases.

### Without committing a passphrase

A single network can come from build-time env vars — the image/deploy targets
build `--impure`, so exported vars reach eval (added at lowest priority):

```sh
export SBC_WIFI_SSID="Home Wi-Fi" SBC_WIFI_PSK="hunter2"
bazel run //path:myboard.image_sd -- --no-write
```

> **Security:** the passphrase is written into the NixOS closure, which lives in
> the world-readable `/nix/store` on the device and in the image. Fine for a
> home/lab network on a hobby board; for real secret hygiene use NetworkManager's
> `ensureProfiles.environmentFiles` with a `$VAR` placeholder and provision the
> env file on the device out of band.

## Requirements

- `bazel`/`bazelisk` (pinned 7.7.1) — for the targets.
- `nix` with flakes — required in all cases: building any deploy target realizes
  the hermetic bash from Nix, and the targets drive `nix` to build an image or
  to build/copy/activate a system for deploy. `ssh` for deploy/ssh targets.
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

**Option A — local Linux builder VM.** A NixOS VM that registers as an
`aarch64-linux` builder. Do the one-time config once, then start a VM.

1. One-time Nix config. On plain Nix, add to `/etc/nix/nix.conf`; on Determinate
   Nix, add to `/etc/nix/nix.custom.conf`:

   ```
   extra-trusted-users = <your-username>
   builders = ssh-ng://builder@linux-builder aarch64-linux /etc/nix/builder_ed25519 4 - kvm,benchmark,big-parallel - c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUpCV2N4Yi9CbGFxdDFhdU90RStGOFFVV3JVb3RpQzVxQkorVXVFV2RWQ2Igcm9vdEBuaXhvcwo=
   builders-use-substitutes = true
   ```

   The 8 space-separated `builders` fields are: URI · system · ssh-key ·
   maxjobs · speed · **supported-features** · mandatory-features · base64 host
   key. The `big-parallel` feature is required — the RPi kernel derivation
   demands it, and Nix's scheduler reads this line (not the VM) to decide what to
   dispatch, so it must be declared here.

   And an SSH alias at `/etc/ssh/ssh_config.d/100-linux-builder.conf`:

   ```
   Host linux-builder
     Hostname localhost
     HostKeyAlias linux-builder
     Port 31022
   ```

   Then restart the daemon: `sudo launchctl kickstart -k system/org.nixos.nix-daemon`
   (if that label is absent, find it with `sudo launchctl list | grep -i nix`).

2. Start a builder in a spare terminal and leave it running (it prompts for
   `sudo` once to install the SSH key). The stock VM ships with only **3 GB RAM /
   20 GB disk** and OOMs on the RPi kernel — so bump it. Two ways:

   - **Quickest — resize the stock VM at runtime.** RAM/cores are passed via
     `$QEMU_OPTS`, so no rebuild and it stays 100% cache-served:

     ```sh
     QEMU_OPTS="-m 8192 -smp 6" nix run nixpkgs#darwin.linux-builder
     ```

     (Disk stays 20 GB — usually enough. If a build hits "No space left on
     device", use the flake below for a 60 GB disk.)

   - **Bigger, persistent size — this repo's flake** (8 GB RAM / 60 GB disk / 6
     cores). It `.override`s the *packaged* builder, so the guest closure is
     identical to stock and comes straight from the cache — no bootstrap.
     In-repo (or vendored in-tree), just run the Bazel target:

     ```sh
     bazel run //:linux_builder
     ```

     Standalone (framework not in your tree), run the flake directly — quote the
     URL, since `?`/`#` are shell metacharacters (fish/zsh):

     ```sh
     nix run 'github:fughilli/sbc-deploy?dir=nix/builder#linux-builder'
     ```

3. Build — the targets now work with **no `--builder` flag** (Nix routes the
   `aarch64-linux` builds to the VM):

   ```sh
   bazel run //examples/hello-sbc:hello.image_sd -- --no-write
   ```

> **Don't hand-roll the VM with a fresh `nixosSystem`.** That stamps the nixpkgs
> rev into a *different*, uncached system derivation, which then needs an
> `aarch64-linux` builder to realize — the very builder you're creating (a
> bootstrap deadlock). Overriding the packaged `darwin.linux-builder` (what the
> flake does) keeps the cached guest. If you *do* run `nix-darwin`, its
> `nix.linux-builder.enable = true` module is the cleanest managed equivalent.

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

### Persisting the build cache (so you can stop the builder)

The builder VM's store already survives a **stop/restart** (it's on the
persistent qcow2, not tmpfs) — `shutdown now` in its console when idle, restart
with `bazel run //:linux_builder`, and the compiled kernel is still there. You
only lose it if you *delete/recreate* the qcow2.

To also survive recreating the VM — and to make the cache a real, restartable
service — run a **binary cache** on the Mac that serves its (persistent) nix
store:

```sh
bazel run //:cache        # harmonia; leave it running. Ctrl-C to stop, re-run to restart.
```

On first run it generates a signing key under `~/.config/sbc-deploy/` and prints
the **public key**. Add that key and the cache URL to your Nix config
(`/etc/nix/nix.custom.conf` on Determinate, else `/etc/nix/nix.conf`), then
restart the daemon:

```
extra-substituters = http://localhost:5000
extra-trusted-public-keys = sbc-deploy-cache-1:AAAA…   # the printed key
```

How it helps: the cache serves the Mac store, and **build artifacts land in the
Mac store whenever the Mac realizes them** — in particular `deploy_live` builds
the system closure (which contains the kernel), so after one deploy the kernel
is cached. A freshly recreated builder then gets the kernel from the Mac
(copied as a build input, or substituted from the cache) instead of recompiling.

To let the builder VM substitute over HTTP directly, add
`extra-substituters = http://10.0.2.2:5000` (the QEMU host gateway) to the
*builder's* nix config — but note that changing the builder's guest config makes
it miss the cached VM image (a one-time rebuild); the copy-as-input path above
needs no builder change.

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
    defs.bzl                   # sbc_application macro (public API)
    scripts/launch.sh          # runfiles launcher: exec nix bash on the script
    scripts/sbc_deploy.sh      # generic image/deploy/keys entrypoint
  nix/
    flake.nix                  # lib.mkSbcProject / mkSbcSystem + nixosModules.*
    flake.lock                 # pinned inputs
    builder/flake.nix          # sized-up linux-builder VM for macOS hosts
    cache/flake.nix            # restartable harmonia binary cache (//:cache)
    modules/
      sbc-base.nix             # networking / mDNS / firewall
      ssh-deploy.nix           # sshd + deploy-key trust
      app-service.nix          # services.sbcApps.<name> systemd generator
      wifi.nix                 # sbcDeploy.wifi auto-connect (multi-network)
      spi.nix                  # opt-in hardware SPI
  examples/hello-sbc/          # runnable consumer (app + network + 3 modes)
```
