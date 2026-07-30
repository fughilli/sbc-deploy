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
- `deploy/defs.bzl` — `sbc_deploy()` macro (public API). Uses `Label("//deploy:…")`
  so it resolves to `@sbc_deploy` from any consuming repo.
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

### NOT verified / known ceilings

- **Full `nixos-raspberrypi` eval OOM-kills on this ~3.8 GB container** (exit
  137, during nixpkgs fetch) — got through the whole input graph + into eval
  with no expression errors first. Host-resource limit, same as the splanc
  module documented (it built to the kernel-compile step on an 8 GB aarch64
  host). **Needs a bigger aarch64 builder to prove the image builds end-to-end.**
- No flashing, **no real-hardware first boot**, no live `deploy_live` switch.
- Only `raspberry-pi-5` exercised; `raspberry-pi-4` untried.
- The `hello-sbc` app is a placeholder (`python3 -m http.server`).

---

## Next steps (roughly ordered)

1. Build the `hello-sbc` SD image end-to-end on a builder with ≥8 GB RAM /
   ~25 GB free scratch (or a cache serving the pinned RPi kernel). Prove
   `bazel run //examples/hello-sbc:hello.image_sd -- --no-write` realizes an
   `*.img.zst`.
2. Flash + boot on a real Pi 5: confirm mDNS (`hello.local`), passwordless root
   SSH via the baked deploy key, and the `sbc-hello` unit runs. Then a live
   `deploy_live` switch.
3. Once solid, vendor back into splanc: re-express `pi/provisioning` in terms of
   `services.sbcApps` (led-driver = realtime + spi module; led-server =
   bindPrivilegedPorts + stateDirectory) and consume `@sbc_deploy` via
   `git_override`.
4. Optional: `raspberry-pi-4` path; AP-mode module (hostapd/dnsmasq seam noted
   in `sbc-base.nix`); a `deploy_live --dry-run` smoke path in CI (no nix build).

---

## Log

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
40 GB disk, plus a "don't hand-roll the VM" warning. Default stock sizes: 3 GB
RAM / 20 GB disk.

### 2026-07-30 — sized-up linux-builder VM flake

Added `nix/builder/flake.nix`: the nixpkgs `darwin.linux-builder` VM sized to
8 GB / 40 GB / 6 cores (the stock ~3 GB VM OOMs on the RPi kernel), exposed as
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
