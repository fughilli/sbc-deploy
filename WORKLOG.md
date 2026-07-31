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
