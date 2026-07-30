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

### 2026-07-30 — initial port

Ported and generalized splanc `pi/provisioning` → this repo. Commits:
`Initial scaffold` → `Port SBC deploy tooling…` → `hello-sbc: commit generated
flake.lock`. Generalized the LED-specific units into `services.sbcApps`, the
LEDMAPPER_* env/paths into SBC_*/flag-driven config, and the three sh_binary
wrappers into one macro + one script. Fixed a real gitignore leak (nested
`secrets/` not matched by `secrets/*`). Verification as above.
