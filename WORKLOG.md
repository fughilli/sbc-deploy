# sbc-deploy — worklog

Handoff notes for a fresh agent (no memory of prior sessions). Read this before
touching code; append to it at the end of a session. Newest entry first.
Git history is the source of truth for *what changed*; this file records *why*,
*what's verified*, and *what's next*.

---

## State of the world

`sbc-deploy` is a reusable **Bazel + Nix** framework for deploying packaged apps
to single-board computers, extracted/generalized from the `pi/provisioning`
tooling in `fughilli/splanc`. It will be vendored back into splanc once solid.

- **Repo:** `git@github.com:fughilli/sbc-deploy.git`, branch `main`. Developed as
  a gitignored nested checkout under a host container's `/workspace/sbc-deploy`
  (kept out of the splanc working tree). git uses `core.sshCommand` with the
  container's deploy key; push works from the container.
- **What it produces:** `lib.mkSbcSystem` builds a Raspberry Pi NixOS system +
  SD image; the `sbc_deploy()` Bazel macro gives `image_sd` / `deploy_live` /
  `keys` targets that shell out to `nix` / `nixos-rebuild`.

### Layout / where things are

- `nix/flake.nix` — `lib.mkSbcSystem`, `nixosModules.*`; inputs pinned in
  `nix/flake.lock` (nixpkgs 25.05, nixos-raspberrypi v1.20260517.0). Lock copied
  from the verified splanc one (same inputs).
- `nix/modules/app-service.nix` — **the core generalization.** Generic
  `services.sbcApps.<name>` submodule → hardened systemd unit + service user +
  runtime/state dirs + firewall openings. Replaces splanc's hardcoded
  led-driver/led-server units.
- `nix/modules/{sbc-base,ssh-deploy}.nix` — always-on (networking/mDNS/firewall;
  key-only sshd + deploy-key trust). `nix/modules/spi.nix` — opt-in hardware.
- `deploy/defs.bzl` — `sbc_application()` macro (public API): emits `.image_sd`
  (base+app), `.image_sd_base` (base only), `.deploy_live` (full switch),
  `.keys`. Uses `Label("//deploy:…")` so it resolves to `@sbc_deploy` from any
  consuming repo. Pairs with `lib.mkSbcProject` on the Nix side.
- `deploy/scripts/sbc_deploy.sh` — one generic script backing all three targets
  (subcommands image|deploy|keys); config baked via sh_binary `args`, paths
  anchored on `BUILD_WORKSPACE_DIRECTORY`. `--` forwards the rest to nix verbatim.
- `examples/hello-sbc/` — runnable consumer; dogfoods the macro + flake lib.
  References the framework as `github:fughilli/sbc-deploy?dir=nix` (its
  `flake.lock` is committed). Local-dev override:
  `-- --override-input sbc-deploy path:/abs/.../sbc-deploy/nix`.

### Verified (dev container: aarch64, Determinate Nix 3.21.8, Bazel 7.7.1)

- `bazel build`/`query`/`run //...` clean; macro generates the 3 targets.
- `keys init/pub/path` generate a real ed25519 pair into the example's
  gitignored `secrets/`. Deploy keys are matched by `**/secrets/*` in
  `.gitignore` (a mid-slash `secrets/*` anchors to repo root and does NOT match
  nested dirs — confirmed with `git check-ignore`).
- Framework flake + lock resolve; example locks fully against the framework via
  both a local override and the pushed github ref.

### Verified on real hardware (Pi 5, 2026-07-31)

**Full loop proven end-to-end** on the user's Apple-Silicon Mac + a Pi 5:
build (sized linux-builder VM) → flash (`image_sd --device`, pv progress) → boot
→ WiFi auto-connect (from `wifi_config_file`) → mDNS `hello.local` → passwordless
root SSH via the baked deploy key (`.ssh` target) → `sbc-hello` unit active →
live redeploy (`deploy_live`: nix build + nix copy + switch-to-configuration)
switched the running system to a new generation and restarted the app. RPi
firmware/bootloader + generation install all worked; NTP synced the clock.

### Still not verified / known ceilings

- On this ~3.8 GB container a full nixos eval still OOM-kills (container limit,
  not the code) — all real builds happen on the host.
- Only `raspberry-pi-5` exercised; `raspberry-pi-4` untried.
- The `hello-sbc` app is a placeholder (`python3 -m http.server`).
- `--cross` (FUG-86): the native kernel/firmware pin that broke it is fixed (see
  the 2026-08-07 cross-kernel log entry); still not eval-verified end-to-end. The
  remaining unknown is nixpkgs 25.05's own aarch64-darwin -> aarch64-linux cross
  support for the full closure, which needs `nix` on the Mac to confirm.

---

## Next steps (roughly ordered)

The core framework is proven end-to-end on hardware (see above). Remaining:

1. **Vendor back into splanc** — the original goal. Re-express `pi/provisioning`
   in terms of `services.sbcApps` (led-driver = realtime + spi module;
   led-server = bindPrivilegedPorts + stateDirectory), consume `@sbc_deploy` via
   `git_override` (Bazel) + `framework=` injection, drop the old bespoke units.
2. Swap the placeholder for a real app (a Bazel-built binary exported from a
   flake `packages.<system>`, wired into `services.sbcApps.<name>.package`).
3. Optional: `raspberry-pi-4` path; AP-mode module (hostapd/dnsmasq seam in
   `sbc-base.nix`); `.status`/`.logs` convenience targets; secret hygiene for
   WiFi PSK (NetworkManager `environmentFiles`).

---

## Log

### 2026-08-12 — auto-managed builder works for external `bazel_dep` consumers

The zero-conf macOS builder (2026-08-09, `#3`) only fired when sbc-deploy's `nix/`
was in the consumer's source tree: `start_managed_builder` resolves the builder
flake from `$(repo_root)/$FRAMEWORK_SUBDIR/builder`, and `--framework-subdir` is
only set when the consumer passes `framework=`. External `bazel_dep` consumers
(e.g. splanc's `pi/hitl`, which pins us via a flake input + `git_override`) never
set it, so they got *"Could not auto-start… deferring to globally-configured
builders"* and had to `--cross` or run a builder by hand.

Fix: ship the builder flake in every generated target's **runfiles** and realise
the VM from there when `--framework-subdir` is absent. Bazel already pins our
version, and `nix/builder` is self-contained with its own committed
`flake.lock`, so this needs no in-tree copy, no lock parsing, no network.

- `nix/builder/BUILD.bazel` (new): `filegroup(srcs)` + `exports_files(flake.nix)`.
- `deploy/defs.bzl`: `_BUILDER`/`_BUILDER_SRCS`; add the flake to each target's
  `data` and a 7th `lead` slot (`_tool_target` passes `-`).
- `deploy/scripts/launch.sh`: resolve the 7th arg → export `$SBC_BUILDER_FLAKE`
  (same pattern as `$SBC_BOARD`/`$SBC_ZSTD`).
- `deploy/scripts/sbc_deploy.sh`: `start_managed_builder` prefers
  `--framework-subdir` (unchanged), else falls back to
  `dirname $SBC_BUILDER_FLAKE`. `--override-input` still only fires with an
  explicit `--framework-subdir`, so external consumers keep evaluating their own
  pinned input. Fully back-compatible.

**Verified:** `bash -n` both scripts; buildifier clean (pre-existing warnings
only); `bazel query` — `//nix/builder:{srcs,flake.nix}` resolve and
`labels(data, //examples/hello-sbc:hello.image_sd)` now includes
`//nix/builder:srcs`. **NOT yet verified: the runfiles `path:` realisation on a
real Apple-Silicon Mac** (no macOS in the dev container) — this is the merge
gate: confirm `bazel run …image_sd` on macOS auto-boots the sized VM from the
runfiles builder flake and tears it down at exit.

### 2026-08-09 — super-lean base image (`lean` attribute)

Added an `sbc_application(lean = True)` attribute for a super-lean headless-
appliance image, flowing Bazel -> `$SBC_LEAN` -> `mkSbcSystem` (env over the new
`leanImage` arg; same seam as board/hostname). `--lean` flag in sbc_deploy.sh
exports SBC_LEAN. When on, `mkSbcSystem`:
- `disabledModules` the RPi sd-image's `profiles/base.nix` — checked upstream, it
  only sets a rescue toolkit (vim/testdisk/ddrescue/sshfs/tcpdump/smartmontools/
  …), a broad `supportedFilesystems` set, and a ZFS `hostId`; none wanted on a
  headless ext4/vfat board (ext4/vfat drivers come from the mounts). Note:
  disabledModules is a top-level module key (can't be `mkIf`-gated), so it reads
  `resolvedLean` directly — hence the arg/env seam rather than a NixOS option.
- `documentation.{enable,man,nixos,doc,info} = mkForce false` and
  `environment.defaultPackages = mkForce []` (drops perl/rsync/strace).
Example sets `lean = True`. Bazel-validated in-container (`--lean` in the image
args). **NOT yet nix-eval'd / built** (no nix in the container, build server was
down) — needs a build + boot test on the Mac to confirm eval + the size delta.
Est. a few hundred MB off the ~1.6 GiB closure.

### 2026-08-09 — board is a first-class rule attribute (+ Pi 3B support)

`board` was buried in the consumer's Nix flake (`mkSbcProject { board = … }`).
Made it a first-class Bazel attribute fed by board-definition targets:
- `deploy/boards.bzl` — `sbc_board` rule + `SbcBoardInfo` provider (fields: the
  nixos-raspberrypi board name + optional submodules like `display-vc4`). It
  writes a two-line file (board name / comma-joined modules).
- `deploy/boards/BUILD.bazel` — predefined targets rpi 5/4/3/02.
- `sbc_application(board = "@sbc_deploy//deploy/boards:raspberry-pi-3")` — the
  board file becomes the 6th launcher lead arg; `launch.sh` reads it and exports
  `$SBC_BOARD` / `$SBC_BOARD_MODULES`; `mkSbcSystem`/`mkSbcProject` resolve those
  (env over arg) — same impure-eval seam as hostname/wifi. `_tool_target` (builder/
  cache) passes a `-` sentinel. Consumers define custom boards via
  `load("@sbc_deploy//deploy:boards.bzl", "sbc_board")`.
- Nix: replaced the hardcoded `${board}` uses with `resolvedBoard`; optional board
  submodules are imported from `resolvedBoardModules`, filtered to those the board
  actually provides (`… .${m} or null`), so a board without one (the Pi 3 has no
  display-vc4) still evaluates. Example now sets `board` in BUILD.bazel and drops
  it from the flake.

**Verified on hardware:** a Pi 3B image (`board = …:raspberry-pi-3`) built via the
managed builder, flashed, boots, connects to WiFi (so leanFirmware kept the right
blob), and accepts SSH. Bazel side validated in-container (board targets build,
correct file content, board file lands in the target's args+data). Note: the Pi 3
kernel (`linux_rpi-bcm2711`) is NOT in nixos-raspberrypi's binary cache for this
rev, so it compiles from source — needs a roomy builder disk (use
`SBC_BUILDER_DISK=/big/volume/…` to avoid filling the Mac's main disk; an I/O
error mid-kernel-build is that host disk filling up).

### 2026-08-07 — image slimming + builder-disk profiling

User asked why the ephemeral builder disk hits ~22 GiB and whether it's genuine.
Profiled (via the build server, sshing into a `--keep-builder` VM). Findings:

- **Builder guest store after a build: 6.5 GiB, but the host qcow2 hit 17 GiB.**
  The 10.5 GiB gap is transient build scratch (uncompressed ext4 rootfs + build
  deps) freed inside the VM but never returned to the host — **qcow2 has no
  discard/trim**, so the file stays at its high-water mark. Ephemeral delete
  (default) zeroes it at rest; the "22 GiB" is the *peak during a build*.
- Of the 6.5 GiB guest store: ~2.8 GiB is the built image outputs
  (`nixos-image` + `ext4-fs.img.zst`) that are ALREADY copied to the Mac — pure
  reclaimable cruft on the builder; ~3.1 GiB is the target runtime closure;
  ~1.2 GiB is build-only (nixpkgs `source` 425M, the builder's own kernel 276M,
  gcc/binutils/grub/nix).
- **Target-image cruft found + partly cut.** The Pi image shipped ~0.9 GiB of
  desktop cruft from NixOS's default **NetworkManager VPN plugins**
  (openconnect→webkitgtk, sstp-gnome→gtk4→gst→wildmidi→freepats, flite…). A
  headless WiFi SBC needs none. Fixed in `sbc-base.nix`:
  `networking.networkmanager.plugins = mkForce []`. Verified: closure **3.5 →
  2.6 GiB**, webkitgtk/plugins gone. Smaller closure ⇒ smaller ext4 ⇒ smaller
  builder peak too, so it helps both.
- **Filesystem toolkit trim (done).** The RPi sd-image's `profiles/base.nix`
  enabled a broad rescue set `boot.supportedFilesystems = { btrfs cifs ext4 f2fs
  ntfs vfat xfs zfs }`, dragging zfs-user, btrfs-progs, cifs-utils(->samba 110M),
  ntfs-3g, xfsprogs, f2fs-tools + kernel modules into a headless app image that
  only mounts vfat /boot + ext4 root. `sbc-base.nix` now mkForces those false.
  Closure **2.6 -> 2.3 GiB** (total NM+fs trim: **3.5 -> 2.3 GiB**).
- **Generic linux-firmware trim (now default ON).** `sbcDeploy.leanFirmware`
  (default true) mkForces `enableRedistributableFirmware = false`, dropping the
  731M blob. CAVEAT found by building it: nixpkgs' all-firmware.nix gates the
  Pi's OWN wifi/BT firmware on that same flag, so it vanished too — WiFi would
  break. Fixed by adding `hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ]`
  back explicitly under the same mkIf. Result: `linux-firmware` gone,
  `raspberrypi-wireless-firmware` kept. Closure **2.3 -> ~1.6 GiB** (total from
  the original 3.5 GiB: **-1.9 GiB, ~54%**). Set `sbcDeploy.leanFirmware = false`
  to restore the full blob. NEEDS a hardware boot to confirm WiFi/BT still work.

**GC-as-we-go / qcow2 discard (user's question) — investigated, NOT done.** Tried
`discard=unmap` on the builder's root qcow2 drive (easy, darwin-side only — it
re-gens just run-nixos-vm, guest stays cache-served) + a post-build `fstrim`. But
reclaiming needs the fstrim to run as root IN the guest, and the stock
darwin-builder `builder` user has NO root (verified: no passwordless sudo, root
ssh disabled). Granting it / mounting the store with continuous `discard` /
`services.fstrim` all change the GUEST closure, forfeiting the byte-identical
cache-served guest and re-triggering a from-source guest build every nixpkgs
bump — a bad trade, especially since the default disk is EPHEMERAL (deleted on
stop, ~0 at rest) and discard wouldn't lower the ephemeral *peak* anyway (no trim
happens mid-build). Reverted both. The real, done lever for the peak is trimming
the target closure (a full copy of it lands in the ext4 image during assembly, so
−1.2 GiB closure ≈ −2.4 GiB peak). Profiling detail: builder guest holds ~6.5 GiB
after a build (2.8 GiB of it the built image outputs already copied to the Mac),
but the host qcow2 hit 17-18 GiB — transient scratch the qcow2 never reclaims.

### 2026-08-07 — genuinely-cached re-runs + auto-managed builder + macOS cross verdict

Big session on the macOS build UX (driven live against the user's Mac via a new
`tools/mac-build-server.py` — a token-gated HTTP server that streams `bazel/nix`
runs and arbitrary `/run` commands back to the container; that's how everything
below was tested without nix here).

**Caching (the user's main complaint: re-runs still needed the builder + were
slow even when "cached").** Root-caused via dry-run + `nix-store --gc
--print-dead`: the script built with `--no-link`, so the image and its 11
config-specific derivations (image, app, root-authorized_keys, the
systemd/NetworkManager units — none in any binary cache) were UNROOTED, and
Determinate's aggressive auto-GC reaped them between runs → every re-run rebuilt
them on the builder. Fix: `gc_root_link()` + `--out-link .sbc-build/<proj>.<attr>`
in cmd_image/cmd_deploy roots the whole closure. Verified on hardware-adjacent
Mac: after a build the image left the dead set; a cached re-run with the builder
**shut down** completes in ~8s touching the builder zero times.

**Auto-managed builder (single command, zero-conf, auto start/stop).** The Mac's
builder was a hand-started foreground QEMU VM (Determinate only wrote the
`builders` config line; it doesn't run the VM). New default on darwin (no
--cross/--builder): `prepare_backend` does a `--dry-run` first; only if something
"will be built" does `ensure_managed_builder` boot the sized VM, dispatch, and
stop it after (EXIT trap). Fully-cached re-runs never boot it. Zero sudo / zero
/etc/nix: boots the packaged `darwin.linux-builder`'s `run-builder` DIRECTLY with
an sbc-deploy-owned key (`~/.config/sbc-deploy/builder-keys`), which SKIPS
`create-builder`'s `add-keys` credential sync (the only part needing sudo — it
rewrites /etc/nix). Dispatch is inline `--builders "ssh-ng://builder@linux-builder
aarch64-linux <ourkey> 6 - big-parallel,kvm,benchmark - <hostkey>"` — works
because the user is in `trusted-users` (Determinate default) and the
`linux-builder` ssh alias (in /etc/ssh/ssh_config.d/, which the root daemon
reads) supplies host:port. `--keep-builder`/`SBC_KEEP_BUILDER` leaves it up. The VM disk (`NIX_DISK_IMAGE`,
else run-nixos-vm drops `./nixos.qcow2` in CWD) is pinned and **ephemeral by
default** — it's pure scratch (Mac store is authoritative) and a qcow2 hoards the
whole substituted closure (~20 GB) without shrinking on in-VM GC, so it's deleted
on stop; `SBC_BUILDER_DISK=<path>` keeps it (persists the builder store for faster
cold builds).
Verified end-to-end on the user's Mac (via the build server): "already up" path,
"cached → no boot" path (8-9s, builder stays down), and the full
boot→build→copy-back→stop lifecycle (forced with `--hostname test2`), then a
cached re-run of that same config touching the builder zero times. Two bugs found
and fixed mid-test: (1) `needs_realisation` used `nix --dry-run | grep -q`, and
under `pipefail` grep's early close SIGPIPE'd nix → flakily reported "nothing to
build" (fixed: capture then glob-match, no pipe); (2) sshd-readiness race — we
dispatched as soon as the port opened, before auth was ready (fixed:
`wait_builder_ready` retries the key probe, also capturing the host key).

**macOS full-cross verdict (FUG-86 follow-up).** Confirmed the kernel/firmware
re-source (below) works — cross eval enters cross mode. But
aarch64-darwin→aarch64-linux full-closure cross hits genuine walls, in order:
(1) systemd's BPF framework pulls Linux-only `bpftool` as a build-host tool →
disabled via overlay (`withLibBPF=false`) when buildPlatform is non-Linux;
(2) portable-but-`platforms=linux`-marked build tools (yodl for zsh docs) →
cleared with `nixpkgs.config.allowUnsupportedSystem` (cross-from-non-Linux only);
(3) **fundamental:** NetworkManager (and the whole gobject-introspection
ecosystem) runs freshly-built *target* aarch64-linux binaries at build time
(introspection), which needs qemu-user — Linux-only; macOS has no way to run
Linux binaries without a VM. NetworkManager itself can't be built for macOS
(libnl/netlink). So "cross everything on macOS" is not achievable; the managed
builder VM is the right answer there. The cross fixes (1)+(2) plus the
kernel/firmware re-source DO make `--cross` viable on a **Linux** host (x86_64 →
aarch64), where qemu-user exists. Kept `--cross` for that.

### 2026-08-07 — cross-build fix: re-source kernel + firmware from the cross pkgs

`bazel run …:hello.image_sd -- --cross` still failed on the user's Apple-Silicon
Mac. Root-caused it (no nix here; traced upstream `nvmd/nixos-raspberrypi`
@v1.20260517.0 by cloning it): the WORKLOG's suspected gap (a pinned
`nixpkgs.pkgs`) was NOT the problem — `nixos-raspberrypi.lib.nixosSystem`
forwards to the stock `nixpkgs.lib.nixosSystem`, so our `nixpkgs.buildPlatform`
seam is accepted. The real defeater: the board module
(`modules/raspberry-pi-5/default.nix`) sources the two heaviest derivations from
`nixos-raspberrypi.packages.${pkgs.stdenv.hostPlatform.system}` — i.e.
`boot.kernelPackages` and `boot.loader.raspberry-pi.firmwarePackage`. Those flake
outputs are a *native* `import nixpkgs { system = "aarch64-linux"; }`
(`mkRpiPkgs` in the upstream flake.nix) that ignores `buildPlatform` entirely, so
they always demand an aarch64-linux builder — the exact thing `--cross` exists to
avoid. `buildPlatform` only steers the system's own `pkgs`; the kernel/firmware
sidestepped it.

Fix (nix/flake.nix, in the existing cross module, cross-only via the same
`mkIf`): `boot.kernelPackages = lib.mkForce pkgs.linuxPackages_rpiN` and
`boot.loader.raspberry-pi.firmwarePackage = lib.mkForce pkgs.raspberrypifw`,
re-sourcing both from the system `pkgs` where the `kernel-and-firmware` overlay
(applied by upstream's always-on `default-nixos-raspberrypi-config`) exposes the
same attrs. `linuxPackages_rpiN` builds via `buildLinux`, which honours
`stdenv.hostPlatform` and cross-compiles; `raspberrypifw` is prebuilt firmware
(a plain unpack that now runs on the build platform). `kernelPackagesAttr` is
derived from `board` (`raspberry-pi-5` -> `linuxPackages_rpi5`). Native builds
skip the whole module (`mkIf false`), so cached aarch64-on-aarch64 artifacts are
byte-for-byte unchanged.

Audited the rest of the rpi-5 import path for other native pins: `pkgs.rpi` (the
native re-import in `nixpkgs-rpi.nix`) is defined but NOT consumed in the
closure; the SD-image builder is nixpkgs' own `installer/sd-card/sd-image.nix`
(tools in `nativeBuildInputs`, so image assembly runs on the build platform);
wireless firmware reaches `hardware.firmware` via the overlay'd top-level pkgs.
So the kernel + firmware were the only two blockers in-repo.

**Verification ceiling:** no `nix` in this aarch64-linux container, so this is
review-only. The one thing left to confirm on a Mac: whether nixpkgs 25.05
cross-compiles the *whole* aarch64-linux closure from an aarch64-darwin build
platform (kernel via buildLinux is fine; a random userspace pkg could still trip
darwin-cross). Test: `bazel run //examples/hello-sbc:hello.image_sd -- --no-write
--cross` and confirm eval enters cross mode + starts building the kernel locally
(no "a 'aarch64-linux' … is required, but I am a 'aarch64-darwin'").

### 2026-08-07 — cross-building (FUG-86): build aarch64-linux on macOS / x86_64-linux

Added an opt-in cross path so a non-`aarch64-linux` host can realize the image
itself, with no builder VM/box. The board module fixes the system's
`hostPlatform` to `aarch64-linux`; the new cross seam in `mkSbcSystem` sets
`nixpkgs.buildPlatform` to a *different* platform, which flips nixpkgs into
cross-compilation. Resolution order: an explicit `buildPlatform` arg on
`mkSbcSystem`/`mkSbcProject`, then `$SBC_BUILD_PLATFORM`, then `$SBC_CROSS` =>
`builtins.currentSystem` — same getEnv-at-eval seam (`--impure`) as
hostname/wifi/pubkey, inert (`mkIf false`) in the native path so the
aarch64-on-aarch64 build is unchanged. `sbc_deploy.sh` gained a `--cross` flag
(+ `SBC_CROSS` env) on `image`/`deploy`: it exports `SBC_CROSS`, is mutually
exclusive with `--builder` (dispatching vs. cross are the two alternatives; also
`--max-jobs 0` would forbid the local cross build), and prints the
rebuild-from-source warning. No macro change — `--cross` rides the existing flag
parser. README "Building on Apple Silicon" now frames it as builder-vs-cross and
documents Option C; Requirements updated.

Trade-off (documented, not a defect): cross artifacts aren't in the binary
cache, so a cross build rebuilds the world from source, incl. the RPi kernel —
needs ample host RAM/disk. **Verification ceiling:** no `nix` in this worktree,
so verified by review + bash logic tests only (`bash -n` clean; `set_cross_env`
exercised — native no-op, cross exports `SBC_CROSS`, `--cross`+`--builder`
dies). Not eval-verified: whether upstream `nixos-raspberrypi` honours
`nixpkgs.buildPlatform` (it would not if it pins a pre-instantiated
`nixpkgs.pkgs`) — the standard NixOS cross seam assumes it doesn't. Next agent
with `nix` on macOS/x86_64-linux: `… -- --no-write --cross` and confirm eval
enters cross mode (`pkgsCross`) rather than erroring on the platform option.

### 2026-07-31 — isolate nix extension usages (reusability fix)

Vendoring sbc-deploy into splanc surfaced a bug: `nix_pkg.attr` (and `.github`)
are only allowed in the root module OR an isolated extension usage. Fine
standalone (sbc-deploy is root), but as a *dependency* it failed with "Illegal
use of the attr tag". Fixed: `use_extension(..., isolate = True)` on both
nix_repo and nix_pkg in MODULE.bazel, and enabled
`--experimental_isolated_extension_usages` in .bazelrc (also needed standalone
now). Verified: sbc-deploy `bazel build //...` clean; splanc
`//pi/provisioning:ledmapper.keys` builds against the vendored module.

### 2026-07-31 — persistent binary cache (harmonia) + builder persistence note

User wanted to persist the build cache without keeping the builder VM live.
Findings: the builder VM's store is on the persistent qcow2 (writableStore=true,
writableStoreUseTmpfs=false; GC only under ~1 GB free), so it already survives
stop/restart — the earlier kernel recompile was only from *deleting* the qcow2.
For a decoupled, restartable cache (survives VM recreation): added
`nix/cache/flake.nix` — a harmonia runner (writeShellApplication) that
auto-generates a signing key under ~/.config/sbc-deploy and serves the local nix
store on `[::]:5000` (reachable from the QEMU VM at 10.0.2.2). Exposed as
`bazel run //:cache` (sbc_cache macro → new `cache` subcommand → `nix run
path:$fw/cache#cache`; refactored builder+cache into `_tool_target`). Key
mechanism (documented): the Mac store persists build artifacts; the kernel lands
there when the Mac realizes the system closure (deploy_live), so a recreated
builder gets it via copy-as-input or substitution instead of recompiling.
Verified: cache flake evals for darwin (`sbc-cache/bin/sbc-cache`); bazel
build //:cache + query clean. Real harmonia serving untested (no darwin here).

### 2026-07-31 — deploy_live without nixos-rebuild (nix build + copy + switch)

The bundled nixos-rebuild ran but died: `Exec format error` on
`coreutils/bin/mktemp` — it was the aarch64-LINUX nixos-rebuild (baking linux
coreutils `alyxj0…`), not darwin (`7jfjz…`). Confirmed the darwin nixos-rebuild
IS correct (bakes darwin coreutils), but rules_nixpkgs handed us the linux
variant, and nixos-rebuild-on-macOS is fragile regardless. Rewrote cmd_deploy to
do what nixos-rebuild does, with darwin-native tools:
  1. `nix build …#nixosConfigurations.<h>.config.system.build.toplevel` (goes to
     the linux builder like images),
  2. `nix copy --no-check-sigs --to ssh-ng://root@host <toplevel>`,
  3. `ssh … "nix-env -p /nix/var/nix/profiles/system --set <tl> && <tl>/bin/
     switch-to-configuration switch"`.
Uses NIX_SSHOPTS + the deploy key; --override-input/builder args still apply to
step 1. Removed the whole nixos-rebuild bundling (MODULE import, 6th launcher
lead arg, SBC_NIXOS_REBUILD). Verified: bazel build //... clean; stub test shows
the 3 steps assemble. Real remote switch still unverified (no Pi here).

### 2026-07-31 — bundle nixos-rebuild so deploy_live works on macOS

`deploy_live` failed with `'nixos-rebuild' not found` — it's a NixOS tool absent
from a stock macOS/Determinate install. Bundled it from nixpkgs
(`@nixpkgs_nixos_rebuild`, like bash/zstd/pv) as a 6th launcher lead arg →
`SBC_NIXOS_REBUILD` (PATH fallback). It's per-target: only `deploy_live` carries
it (others pass the `-` sentinel), so it stays out of image/ssh/keys closures.
Confirmed from source: the classic nixos-rebuild (25.05 default, not -ng) forwards
`--override-input` to lockFlags (framework injection works through deploy),
accepts `--builders`/`--max-jobs`/`--impure`, but REJECTS unknown flags — so
changed set_builder_args from `--builders-use-substitutes` to the universal
`--option builders-use-substitutes true`. Its wrapper prepends GNU
coreutils/sed/grep/jq/util-linux + nix to PATH (`PATH=@path@:$PATH`), so
`readlink -f` etc. are GNU (macOS-safe) and ssh/nix still resolve. Verified:
bazel build //... clean; stub test shows deploy assembles `nixos-rebuild switch
--flake … --target-host root@… --override-input sbc-deploy path:…/nix` and the
builder flags. Real remote deploy still unverified (no Pi here).

### 2026-07-31 — ssh convenience target

Added an `ssh` subcommand + `<name>.ssh` macro target: `ssh -i <deploy_key> -o
IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new <user>@<host>`, host
defaulting to `<hostName>.local` (mDNS) or a positional override; `-- <args>`
forwarded to ssh (e.g. a remote command). Uses the same key_paths/secrets as
deploy. Verified: bazel query shows hello.ssh; stub test confirms default host,
explicit host, and passthrough-remote-command all assemble correctly.

### 2026-07-31 — flashing progress bar (bundled pv)

Pipe the write through `pv` for a progress bar/ETA on both OSes. Bundled `pv`
from nixpkgs (`@nixpkgs_pv`, like zstd) → 5th launcher lead arg → `SBC_PV`
(falls back to PATH pv; sentinel `-` for the builder target). flash_image now
streams `pv <img.zst> | zstd -dc | dd` (pv reads the compressed file so it
auto-sizes the bar); when pv is absent it keeps the old behavior (Linux `dd
status=progress`, macOS Ctrl-T note). Verified: bazel build clean; pv resolves
(SBC_DEBUG); stub test shows the pv|zstd|dd pipeline + diskutil calls assemble.

### 2026-07-31 — flash fix: image path is a dir; readlink -f is Linux-only

First real flash on the Mac failed (`zstd: … is a directory`, 0 bytes). The
sdImage store output is a DIRECTORY itself named `…img.zst`, with the real image
at `sd-image/*.img.zst` inside; the `find` (no `-type f`) matched the directory.
Also `readlink -f` (used to resolve the out-link) doesn't exist on BSD/macOS.
Fixed: capture the out path from `nix build --no-link --print-out-paths` (stdout)
instead of readlink, and `find … -type f` so it picks the inner file. Mock-tested
the find. (This never surfaced before because prior runs were `--no-write`.)

### 2026-07-31 — cross-platform SD flashing (image_sd --device)

The old flash path was Linux-only (`lsblk`, `dd status=progress conv=fsync`) and
would break on the user's Mac. Rewrote `flash_image` to branch on `uname`:
macOS → `diskutil unmountDisk` + `dd of=/dev/rdiskN bs=4m` (BSD dd, no
status=progress; Ctrl-T for progress) + `diskutil eject`; Linux → `dd of=DEV
bs=4M status=progress conv=fsync`. Bundled `zstd` from nixpkgs (`@nixpkgs_zstd`,
like bash/yj) for turnkey `.img.zst` decompression — resolved by the launcher as
a 4th lead arg and exported as `SBC_ZSTD` (falls back to PATH zstd). Launcher now
reads 4 lead args (script, bash, wifi-or-`-`, zstd-or-`-`); sbc_linux_builder
passes `- -`. Verified: `bazel build //...` clean; bundled zstd resolves
(SBC_DEBUG); stub test confirms the macOS (rdisk/bs=4m/diskutil) and Linux
(bs=4M/status=progress/conv=fsync) dd command assembly. Real flashing to hardware
still untested (no card in the container).

### 2026-07-31 — declarative WiFi via wifi_config_file (YAML)

`sbc_application(wifi_config_file = "wifi.yaml")` — a single YAML list of
networks (ssid/psk/priority/hidden). Converted YAML→JSON in the Bazel graph via
nixpkgs `yj` (imported as `@nixpkgs_yj`, like bash), so Nix reads it with native
`fromJSON` — no YAML parser or import-from-derivation on the Nix side. Plumbing:
macro adds a genrule (`<name>_wifi.json`) + a 3rd launcher lead arg
(rlocationpath, or `-` sentinel when absent); launch.sh resolves it and exports
`SBC_WIFI_CONFIG_JSON`; wifi.nix reads that path and merges into `networks`
(cfg ++ file ++ env). Verified end-to-end on the container: yj genrule output
correct; `keys` run resolves+exports the runfiles JSON path (SBC_DEBUG shows it);
wifi.nix eval yields sbc-wifi-0/1/2 with priorities 100/10/1 and open-vs-wpa-psk.
Example wired live with a placeholder `examples/hello-sbc/wifi.yaml`.

### 2026-07-31 — Bazel drives nix; kill `nix flake update`

User pushback: too many manual nix commands. Fixed the recurring one — the
example fetched the framework from github with its own flake.lock, so it drifted
from the Bazel pin and needed `nix flake update` on every framework change.
Now `sbc_application(framework = "nix")` bakes `--framework-subdir nix`, and the
script injects `--override-input sbc-deploy path:$BUILD_WORKSPACE_DIRECTORY/nix`
into every `nix build` / `nixos-rebuild` (guarded on the dir existing) — so the
in-tree framework is the single source of truth; no lock update. Also added a
`builder` subcommand + `sbc_linux_builder` macro → `//:linux_builder` target
(`bazel run //:linux_builder` starts the sized VM; no manual `nix run`).
Verified via stub nix: image injects the override before the consumer flake;
`builder` runs `nix run path:…/nix/builder#linux-builder`. Bazel query shows
`//:linux_builder` + the 4 app targets.

Irreducible manual bits (documented, not removable by Bazel): one-time host nix
config on macOS (trusted-users + the `builders` line + ssh alias, needs sudo),
and the builder VM being a long-running background process (it's a target now,
but you still leave it running). External bazel_dep consumers without the
framework in-tree still pin it via their flake input (omit `framework`).

### 2026-07-31 — three deployment modes via sbc_application

Restructured the public API around three modes. Nix: added
`lib.mkSbcProject { hostName; appModules; systemModules; board?; }` → returns
`nixosConfigurations.{<host>, <host>-base}` + `images.{sdImage, sdImageBase}`.
full = systemModules ++ appModules; base = systemModules only (networking, so
the base image is reachable for live deploy). Bazel: renamed the macro
`sbc_deploy` → `sbc_application`, now emitting `.image_sd` (mode 1: base+app),
`.image_sd_base` (mode 2: base only, new `--attr images.sdImageBase`),
`.deploy_live` (mode 3: switch running board to full), plus `.keys`. Example
split into `hello-app.nix` (appModules) + `network.nix` (systemModules, holds
the commented wifi). Verified: `bazel query` shows the 4 targets; flake (local
override) exposes nixosConfigurations `[hello, hello-base]` and images
`[sdImage, sdImageBase]`. No script change needed — image_sd_base is just a
different `--attr`. NOTE: renamed macro/attr names are breaking; the example is
updated, no other consumers yet.

### 2026-07-31 — WiFi auto-connect (multi-network + priority)

Added `nix/modules/wifi.nix` (always-on in mkSbcSystem, inert until configured):
`sbcDeploy.wifi.networks = [ { ssid; psk?; hidden?; priority?; } … ]` → one
NetworkManager `ensureProfiles` profile per network. `priority` →
`connection.autoconnect-priority` (higher wins); unset falls back to list order
(earlier = higher, via `count - index`). Single network can also come from
`$SBC_WIFI_SSID`/`$SBC_WIFI_PSK` at eval (`--impure`), appended lowest priority.
Validated by NixOS eval on the container (profiles + priorities correct; open vs
wpa-psk). Passphrase lands in the world-readable store/image — documented, with
the `ensureProfiles.environmentFiles` `$VAR` route noted for secret hygiene.
Note: first real end-to-end SD image (`.img.zst`) was built on the user's Mac
just before this — pipeline proven; WiFi itself still needs a real-hardware boot.

### 2026-07-30 — builders line needs big-parallel feature

First real dispatch to the Mac's linux-builder failed: the RPi kernel derivation
requires the `big-parallel` system feature, but the documented `builders` line
left the supported-features field as `-` (none), so the scheduler found no
matching machine. Feature matching for remote dispatch is CLIENT-side (the
`builders`/machines line), not the builder's own `system-features` — so it must
be declared there. Fixed the README builders line to
`… 4 - kvm,benchmark,big-parallel - <hostkey>`.

### 2026-07-30 — fix builder bootstrap deadlock

The hand-rolled `nix/builder` flake hit a catch-22 on the user's Mac: building
the custom VM required an aarch64-linux builder (the VM itself). Root cause found
by inspection on the container: a fresh `lib.nixosSystem` stamps the nixpkgs rev
into the system derivation (`…-nixos-system-…ac62194`), which is NOT on
cache.nixos.org, so it must be built — but the packaged `darwin.linux-builder`
sets `nixos.revision = null` giving `…-nixos-system-25.05pre-git`, which IS
cached. Also confirmed memory/disk/cores are runtime-only (`-m`/`-smp`/`$QEMU_OPTS`,
disk created at boot) and don't change the guest closure. Fix: rewrote the flake
to `nixpkgs.legacyPackages.<sys>.darwin.linux-builder.override { modules = [size]; }`
— guest stays byte-identical to stock (verified: both eval to
`him26ibjn3sqhfaj5y2bkw854s1vp2vf`, present on cache.nixos.org), so no bootstrap.
README now leads with the zero-rebuild `QEMU_OPTS="-m 8192 -smp 6" nix run
nixpkgs#darwin.linux-builder` (RAM fix; 20 GB disk) and offers the flake for a
60 GB disk, plus a "don't hand-roll the VM" warning. Default stock sizes: 3 GB
RAM / 20 GB disk.

### 2026-07-30 — kernel build filled the 20 GB stock disk

The QEMU_OPTS stock builder (8 GB RAM, 20 GB disk) got deep into the RPi kernel
compile then failed "No space left on device" (auto-GC couldn't free enough).
RAM was fine — purely disk. Bumped the flake's diskSize 40960 → 61440 MiB
(60 GB); user switches from the stock VM to the flake VM to get the bigger disk.

### 2026-07-30 — sized-up linux-builder VM flake

Added `nix/builder/flake.nix`: the nixpkgs `darwin.linux-builder` VM sized to
8 GB / 60 GB / 6 cores (the stock ~3 GB VM OOMs on the RPi kernel), exposed as
`apps.<darwin>.linux-builder` → `nix run …?dir=nix/builder#linux-builder`. Keeps
upstream default keys/host-key/port 31022, so the README's one-time nix.conf
`builders` line + ssh alias apply unchanged. Follows the nixpkgs manual
"Reconfiguring" pattern (nixosSystem + profiles/nix-builder-vm.nix, host arch's
linux twin → native aarch64-linux on Apple Silicon). Validated by eval on the
linux container: `nix eval --system aarch64-darwin …#packages.aarch64-darwin.
linux-builder.drvPath` → real create-builder.drv (all option paths valid); app
`program` → …/bin/create-builder. Actually running/building it needs macOS
(Virtualization.framework) — unverified there. README "Building on Apple Silicon"
updated with the standalone (no-nix-darwin) flow.

### 2026-07-30 — Apple-Silicon build support

On aarch64-darwin the image can't build locally (Linux binaries don't run on
Darwin; error "a 'aarch64-linux' … is required to build … but I am a
'aarch64-darwin'"). Cross-compiling the whole closure is impractical (no cache
reuse). Added a `--builder <spec>` flag + `SBC_NIX_BUILDERS` env to sbc_deploy.sh
that dispatches builds to a native aarch64-linux builder via nix
`--max-jobs 0 --builders-use-substitutes --builders <spec>` (applied to both
`nix build` and `nixos-rebuild`). README "Building on Apple Silicon" documents
the two paths: nix-darwin `nix.linux-builder` (recommended; works with no flags)
and an ad-hoc remote builder via `--builder`. Verified arg assembly with a stub
nix (space-containing `--builders` value stays one arg; empty case clean); a
real remote build wasn't exercised (no second builder in-container).

### 2026-07-30 — hermetic nix bash

macOS ships bash 3.2; `sh_binary` uses the shebang for its interpreter, so the
targets were running under 3.2 and hit `set -u` empty-array + underscore-flag
issues. Fixed properly: every target is now an sh_binary whose src is
`deploy/scripts/launch.sh` (a runfiles-aware, 3.2-safe launcher) that execs a
**nixpkgs-vendored bash** (`@nixpkgs_bash`, imported via `rules_nixpkgs_core` in
MODULE.bazel) on `sbc_deploy.sh`. The macro passes the script + bash
rlocationpaths as the two leading args. Verified in-container: targets run under
`nixpkgs_bash/bin/bash 5.2.37` (`SBC_DEBUG=1` prints the interpreter). Building a
target now realizes bash from Nix (nix already required). Kept the earlier 3.2
guards in sbc_deploy.sh as defense for direct execution.

### 2026-07-30 — initial port

Ported and generalized splanc `pi/provisioning` → this repo. Commits:
`Initial scaffold` → `Port SBC deploy tooling…` → `hello-sbc: commit generated
flake.lock`. Generalized the LED-specific units into `services.sbcApps`, the
LEDMAPPER_* env/paths into SBC_*/flag-driven config, and the three sh_binary
wrappers into one macro + one script. Fixed a real gitignore leak (nested
`secrets/` not matched by `secrets/*`). Verification as above.
