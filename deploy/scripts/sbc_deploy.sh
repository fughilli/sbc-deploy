#!/usr/bin/env bash
# sbc-deploy — unified entrypoint for building/flashing an SBC NixOS image,
# deploying it live, and managing the deploy SSH key.
#
# This one script backs all three Bazel targets created by the `sbc_deploy`
# macro (deploy/defs.bzl); the target bakes in the subcommand + project config
# via the sh_binary `args`, and the operator appends the rest after `--`:
#
#   bazel run //path:NAME.image_sd    -- [--device /dev/sdX] [--no-write] [--hostname <name>] [nix args]
#   bazel run //path:NAME.deploy_live -- <host-or-ip> [--user root] [nix args]
#   bazel run //path:NAME.keys        -- {init|ensure|rotate|path|pub}
#
# Everything is anchored on the SOURCE tree via BUILD_WORKSPACE_DIRECTORY (set
# by `bazel run`), never on the read-only runfiles copy — the flake, the
# secrets dir and the generated key all live in the operator's checkout. This
# is what lets one generic script serve any consuming repo: the macro only has
# to tell it the project name and the workspace-relative flake dir.
#
# Requires `nix` (with flakes) on the host actually running a build or deploy.
# `keys` needs only ssh-keygen; `ssh`/`deploy` need `ssh`.
set -euo pipefail

# Runs under the nixpkgs-vendored bash via launch.sh (see deploy/defs.bzl).
# Set SBC_DEBUG=1 to confirm which interpreter is in use + resolved wifi config.
[[ -n "${SBC_DEBUG:-}" ]] && {
  echo "sbc-deploy: bash=${BASH:-?} ${BASH_VERSION:-?}" >&2
  echo "sbc-deploy: wifi_config_json=${SBC_WIFI_CONFIG_JSON:-<none>}" >&2
  echo "sbc-deploy: zstd=${SBC_ZSTD:-<none>}" >&2
  echo "sbc-deploy: pv=${SBC_PV:-<none>}" >&2
}

# --- config, overridable by flags or environment ---------------------------
SUBCMD="${1:-}"
[[ $# -gt 0 ]] && shift || true

PROJECT="${SBC_PROJECT:-sbc}"          # name; key comment + messages
FLAKE_SUBDIR="${SBC_FLAKE_SUBDIR:-}"   # path to the flake dir, relative to repo root
IMAGE_ATTR="${SBC_IMAGE_ATTR:-images.sdImage}"
HOSTNAME_ATTR="${SBC_HOSTNAME:-}"      # deploy/ssh: nixosConfigurations.<attr>; image: hostname baked in
SECRETS_DIR_OVERRIDE="${SBC_DEPLOY_KEY_DIR:-}"

DEVICE=""
WRITE=1
DEPLOY_USER="root"
DEPLOY_HOST=""
# Remote/VM aarch64-linux build machine(s). On aarch64-darwin (Apple Silicon)
# the host can't build the Linux image locally, so builds must be dispatched to
# a native aarch64-linux builder. Space/semicolon-separated nix `--builders`
# spec; see the README "Building on Apple Silicon".
NIX_BUILDERS="${SBC_NIX_BUILDERS:-}"
# Cross-compile the aarch64-linux closure on THIS host instead of dispatching to
# a native aarch64-linux builder — so macOS / x86_64-linux need no builder VM or
# remote box. Set by --cross or SBC_CROSS; optionally pin the build platform with
# SBC_BUILD_PLATFORM. Trade-off: cross artifacts aren't in the binary cache, so
# this rebuilds from source (incl. the RPi kernel). See the README.
CROSS="${SBC_CROSS:-}"
# Super-lean base image (drop the RPi sd-image rescue toolkit, docs, and default
# extra packages). Set by --lean (the sbc_application `lean` attr) or SBC_LEAN;
# exported as SBC_LEAN for the flake to read at eval. See the README.
LEAN="${SBC_LEAN:-}"
# Workspace-relative path to sbc-deploy's own nix/ flake dir, when it lives in
# the same source tree (in-repo example, or vendored in-tree). When set, builds
# inject it via `--override-input sbc-deploy path:…` so Bazel is the single
# source of the framework version — no `nix flake update` needed. Empty for
# external bazel_dep consumers, who pin the framework via their flake input.
FRAMEWORK_SUBDIR="${SBC_DEPLOY_FRAMEWORK_SUBDIR:-}"
EXTRA_ARGS=()

die() { echo "ERROR: $*" >&2; exit 1; }

# Populate FRAMEWORK_ARGS with an --override-input that points the consumer's
# `sbc-deploy` flake input at the in-tree framework (if present), so the build
# always uses the Bazel-pinned version rather than the flake.lock's github pin.
FRAMEWORK_ARGS=()
set_framework_override() {
  FRAMEWORK_ARGS=()
  [[ -n "$FRAMEWORK_SUBDIR" ]] || return 0
  local fw; fw="$(repo_root)/${FRAMEWORK_SUBDIR%/}"
  [[ -f "$fw/flake.nix" ]] || return 0
  FRAMEWORK_ARGS=(--override-input sbc-deploy "path:$fw")
}

# Populate the global BUILDER_ARGS array with nix flags that dispatch all builds
# to the configured aarch64-linux builder(s). --max-jobs 0 forbids local builds
# (the darwin host can't produce aarch64-linux outputs), while substitution +
# --builders-use-substitutes let both machines still pull from the binary cache.
BUILDER_ARGS=()
set_builder_args() {
  BUILDER_ARGS=()
  [[ -n "$NIX_BUILDERS" ]] || return 0
  echo "==> Dispatching builds to aarch64-linux builder(s): $NIX_BUILDERS" >&2
  # --max-jobs 0 forbids local builds (a darwin host can't produce
  # aarch64-linux); builders-use-substitutes lets the remote builder pull from
  # the binary cache itself.
  BUILDER_ARGS=(--max-jobs 0 --option builders-use-substitutes true --builders "$NIX_BUILDERS")
}

# When --cross / SBC_CROSS is set, export SBC_CROSS so the flake's cross seam
# (read under --impure) pins nixpkgs.buildPlatform to this host and cross-compiles
# the aarch64-linux closure locally — no aarch64-linux builder needed. Mutually
# exclusive with --builder: dispatching to a native builder is the *alternative*
# to cross-compiling, and --max-jobs 0 would forbid the local cross build.
set_cross_env() {
  [[ -n "$CROSS" ]] || return 0
  if [[ -n "$NIX_BUILDERS" ]]; then
    die "--cross and --builder are mutually exclusive: --cross builds the aarch64-linux closure on this host, --builder dispatches it to a native aarch64-linux builder. Pick one."
  fi
  export SBC_CROSS=1
  echo "==> Cross-compiling the aarch64-linux closure on $(uname -sm) (no aarch64-linux builder)." >&2
  echo "    Note: cross artifacts aren't in the binary cache, so this rebuilds from source" >&2
  echo "    (including the RPi kernel). Give the host ample RAM/disk; expect a long first build." >&2
}

# --- auto-managed linux-builder (macOS) ------------------------------------
# On Apple Silicon the host can't build the aarch64-linux image locally, so the
# default (no --cross / no --builder) is to manage the sized builder VM
# automatically: boot it on demand, dispatch the build, and shut it down after.
# It boots the packaged darwin.linux-builder's `run-builder` directly with an
# sbc-deploy-owned SSH key ($KEYS), which SKIPS create-builder's credential sync
# — that sync is the only part that needs `sudo` (it rewrites /etc/nix). So this
# is fully zero-conf: no sudo, no /etc/nix changes. Built outputs are copied back
# into the local /nix/store as usual (and rooted via gc_root_link, so re-runs are
# cached and don't need the builder at all).
BUILDER_STARTED=0
MANAGED_QEMU_PID=""
KEEP_BUILDER="${SBC_KEEP_BUILDER:-0}"
BUILDER_PORT=31022
BUILDER_HOSTKEY_B64=""
BUILDER_KEYS_DIR="${SBC_BUILDER_KEYS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/sbc-deploy/builder-keys}"
# Path for the VM's disk (qcow2). run-nixos-vm defaults this to ./nixos.qcow2 in
# the CWD, which would scatter a large image into the repo. The builder is pure
# scratch (your local /nix/store is the authoritative cache — everything is copied
# back), and a qcow2 accumulates the whole substituted closure (10–20 GB) without
# shrinking on GC, so by DEFAULT the disk is EPHEMERAL: created under the cache dir
# and deleted when the auto-managed VM stops. Set SBC_BUILDER_DISK to a fixed path
# to keep it instead (persists the builder store for faster cold builds, at the
# cost of that disk space — e.g. point it at a roomy volume). --keep-builder also
# keeps the disk (the VM stays up).
if [[ -n "${SBC_BUILDER_DISK:-}" ]]; then
  BUILDER_DISK="$SBC_BUILDER_DISK"; BUILDER_DISK_EPHEMERAL=0
else
  BUILDER_DISK="${XDG_CACHE_HOME:-$HOME/.cache}/sbc-deploy/builder.qcow2"; BUILDER_DISK_EPHEMERAL=1
fi
_builder_key() { echo "$BUILDER_KEYS_DIR/builder_ed25519"; }

# Generate the sbc-deploy builder keypair once (no sudo). The VM authorizes this
# key at boot (via the KEYS virtfs mount); the nix daemon connects with it.
ensure_builder_key() {
  local key; key="$(_builder_key)"
  [[ -f "$key" && -f "$key.pub" ]] && return 0
  mkdir -p "$BUILDER_KEYS_DIR"; chmod 700 "$BUILDER_KEYS_DIR"
  echo "==> Generating sbc-deploy builder key (one-time, no sudo): $key" >&2
  rm -f "$key" "$key.pub"
  ssh-keygen -q -t ed25519 -N "" -C "sbc-deploy-builder" -f "$key"
}

builder_port_open() { nc -z -G1 localhost "$BUILDER_PORT" >/dev/null 2>&1; }

# SSH to the builder with our key; succeeds only if the running VM authorizes it.
# On success, captures the VM's host key (base64) into BUILDER_HOSTKEY_B64 for
# the inline --builders spec.
builder_probe_ourkey() {
  local kh; kh="$(mktemp)"
  if ssh -i "$(_builder_key)" -p "$BUILDER_PORT" \
        -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$kh" -o ConnectTimeout=5 -o BatchMode=yes \
        builder@localhost true >/dev/null 2>&1; then
    BUILDER_HOSTKEY_B64="$(awk '{print $2, $3}' "$kh" | base64 | tr -d '\n')"
    rm -f "$kh"; return 0
  fi
  rm -f "$kh"; return 1
}

# Boot the sized VM in the background with our key. Resolves the builder flake
# two ways, in precedence order: an in-tree framework (--framework-subdir, for
# vendored/in-repo consumers), else the Bazel-pinned builder flake shipped in the
# target's runfiles ($SBC_BUILDER_FLAKE, set by the launcher) — so external
# bazel_dep consumers get the auto-managed builder with no in-tree copy. Returns
# non-zero if neither is available.
start_managed_builder() {
  local bflake
  if [[ -n "$FRAMEWORK_SUBDIR" ]]; then
    bflake="$(repo_root)/${FRAMEWORK_SUBDIR%/}/builder"        # in-tree / vendored framework
  elif [[ -n "${SBC_BUILDER_FLAKE:-}" ]]; then
    bflake="$(dirname "$SBC_BUILDER_FLAKE")"                    # Bazel-pinned builder from runfiles
  else
    return 1
  fi
  [[ -f "$bflake/flake.nix" ]] || return 1
  # Extract run-builder (the boot half of create-builder) so we can boot with our
  # own $KEYS and skip add-keys' sudo credential sync.
  local installer runb
  installer="$(nix build --no-link --print-out-paths "path:${bflake}#linux-builder" 2>/dev/null | tail -n1)" || return 1
  [[ -n "$installer" ]] || return 1
  runb="$(grep -oE '/nix/store/[a-z0-9]+-run-builder/bin/run-builder' "$installer/bin/create-builder" | head -n1)"
  [[ -n "$runb" ]] || return 1
  echo "==> Starting auto-managed linux-builder VM (will stop when done; --keep-builder to keep)…" >&2
  local log; log="$(repo_root)/.sbc-build/builder.log"; mkdir -p "$(dirname "$log")"
  mkdir -p "$(dirname "$BUILDER_DISK")"
  # KEYS: our key the VM authorizes; NIX_DISK_IMAGE: stable persistent disk (not
  # ./nixos.qcow2 in the CWD). run-nixos-vm cd's to a tmpdir for everything else.
  KEYS="$BUILDER_KEYS_DIR" NIX_DISK_IMAGE="$BUILDER_DISK" nohup "$runb" >"$log" 2>&1 &
  local i
  for i in $(seq 1 180); do builder_port_open && break; sleep 1; done
  builder_port_open || { echo "ERROR: builder VM did not come up on :$BUILDER_PORT (see $log)." >&2; return 1; }
  MANAGED_QEMU_PID="$(pgrep -f "qemu-system-aarch64.*hostfwd=tcp::${BUILDER_PORT}-" | head -n1)"
  BUILDER_STARTED=1
}

# Shut down a builder VM we started (no-op if we didn't, or if --keep-builder).
# Wired to EXIT so it runs on any exit path.
stop_managed_builder() {
  [[ "$BUILDER_STARTED" == 1 ]] || return 0
  if [[ "$KEEP_BUILDER" == 1 ]]; then
    echo "==> Leaving builder VM running (--keep-builder). Stop it later with: pkill -f 'hostfwd=tcp::${BUILDER_PORT}-'" >&2
    return 0
  fi
  echo "==> Stopping auto-managed builder VM…" >&2
  if [[ -n "$MANAGED_QEMU_PID" ]]; then kill "$MANAGED_QEMU_PID" 2>/dev/null || true
  else pkill -f "qemu-system-aarch64.*hostfwd=tcp::${BUILDER_PORT}-" 2>/dev/null || true; fi
  BUILDER_STARTED=0
  # Reclaim the scratch disk (qcow2 doesn't shrink on in-VM GC). Kept only if the
  # user pinned a fixed SBC_BUILDER_DISK. Give qemu a moment to release the file.
  if [[ "${BUILDER_DISK_EPHEMERAL:-0}" == 1 && -f "$BUILDER_DISK" ]]; then
    sleep 1
    rm -f "$BUILDER_DISK" && echo "==> Reclaimed ephemeral builder disk (set SBC_BUILDER_DISK to keep it)." >&2
  fi
}

# Wait until the builder actually answers SSH auth with our key (sshd readiness
# lags the port opening at boot), capturing the host key en route. Returns 0 once
# ready, 1 on timeout. This is what avoids the race where we dispatch before the
# VM can authenticate.
wait_builder_ready() {
  local secs="${1:-90}" i
  for i in $(seq 1 "$secs"); do
    builder_probe_ourkey && return 0
    sleep 1
  done
  return 1
}

_set_managed_builder_args() {
  BUILDER_ARGS=(--max-jobs 0 --option builders-use-substitutes true \
    --builders "ssh-ng://builder@linux-builder aarch64-linux $(_builder_key) 6 - big-parallel,kvm,benchmark - $BUILDER_HOSTKEY_B64")
  echo "==> Using auto-managed aarch64-linux builder VM." >&2
}

# macOS default backend: ensure a builder VM that accepts our key is up, then
# point BUILDER_ARGS at it. If a builder is already up but doesn't accept our key
# (e.g. one the user started by hand), defer to the globally-configured builders.
ensure_managed_builder() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  ensure_builder_key
  trap stop_managed_builder EXIT   # no-op unless we start one below
  if builder_port_open; then
    # Something's already listening. Give it a short window to accept our key
    # (it might be one we left running); otherwise defer to global config.
    if wait_builder_ready 10; then _set_managed_builder_args; return 0; fi
    echo "==> A builder on :$BUILDER_PORT doesn't accept the sbc-deploy key; using globally-configured builders." >&2
    return 0
  fi
  start_managed_builder || {
    echo "==> Could not auto-start a builder; deferring to globally-configured builders." >&2
    echo "    (Auto-start needs the builder flake: run via the sbc_application-generated target (ships it in runfiles), pass --framework-subdir, or use --builder/--cross.)" >&2
    return 0
  }
  # Our VM's port is up; now wait for sshd to accept our key before dispatching.
  if wait_builder_ready 90; then
    _set_managed_builder_args
  else
    echo "ERROR: builder VM booted but SSH with the sbc-deploy key never became ready (see .sbc-build/builder.log)." >&2
  fi
}

# Does realising this flake ref actually require building anything (vs. being
# fully cached or substitutable)? A `--dry-run` plans without building; "will be
# built" means real work — the only case that needs a builder. "will be fetched"
# (substitutes) and an empty plan do not. Cheap (a few seconds of eval), and it's
# what lets a cached re-run skip the builder VM entirely.
needs_realisation() {
  local ref="$1" out
  # Capture then glob-match rather than pipe to `grep -q`: under `set -o
  # pipefail`, grep -q closes the pipe on first match, nix gets SIGPIPE (exit
  # 141), and the pipeline is reported as failed — which made this flakily return
  # "nothing to build" even when there was.
  out="$(nix build --dry-run \
    ${FRAMEWORK_ARGS[@]+"${FRAMEWORK_ARGS[@]}"} \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
    --impure "$ref" 2>&1)" || true
  [[ "$out" == *"will be built"* ]]
}

# Choose the build backend for realising $1 (a flake ref). Explicit --cross or
# --builder win. Otherwise, on macOS, auto-manage the sized VM — but only spin it
# up when a build is actually needed, so fully-cached re-runs stay builder-free.
prepare_backend() {
  local ref="$1"
  set_framework_override
  if [[ -n "$CROSS" ]]; then set_cross_env; return 0; fi
  if [[ -n "$NIX_BUILDERS" ]]; then set_builder_args; return 0; fi
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  if needs_realisation "$ref"; then
    ensure_managed_builder
  else
    echo "==> Fully cached — nothing to build, no builder needed." >&2
  fi
}

# --- resolve paths against the real source tree ----------------------------
repo_root() {
  if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
    echo "$BUILD_WORKSPACE_DIRECTORY"
  else
    # Direct invocation (not via `bazel run`): assume CWD is the repo root.
    pwd
  fi
}

# --- argument parsing (recognized flags consumed, rest passed to nix) -------
parse_common_flags() {
  local a
  while [[ $# -gt 0 ]]; do
    a="$1"
    case "$a" in
      --project)      PROJECT="$2"; shift 2 ;;
      --flake-subdir) FLAKE_SUBDIR="$2"; shift 2 ;;
      --attr)         IMAGE_ATTR="$2"; shift 2 ;;
      --hostname)     HOSTNAME_ATTR="$2"; shift 2 ;;
      --framework-subdir) FRAMEWORK_SUBDIR="$2"; shift 2 ;;
      --secrets-dir)  SECRETS_DIR_OVERRIDE="$2"; shift 2 ;;
      --device)          DEVICE="$2"; shift 2 ;;
      --no-write|--no_write) WRITE=0; shift ;;
      --user)            DEPLOY_USER="$2"; shift 2 ;;
      --builder)         # append; nix separates multiple builders with ';'
                         NIX_BUILDERS="${NIX_BUILDERS:+$NIX_BUILDERS ; }$2"; shift 2 ;;
      --cross)           CROSS=1; shift ;;
      --lean)            LEAN=1; shift ;;
      --keep-builder)    KEEP_BUILDER=1; shift ;;
      --)                # everything after `--` is forwarded verbatim to nix
                         shift
                         while [[ $# -gt 0 ]]; do EXTRA_ARGS+=("$1"); shift; done ;;
      -*)                die "unrecognized option '$a'. Recognized: --device <dev>, --no-write, --hostname <name>, --user <name>, --builder <spec>, --cross, --lean, --keep-builder. To pass flags to nix, put them after a literal '--' (e.g. '-- -- --dry-run')." ;;
      *)                 POSITIONAL+=("$a"); shift ;;
    esac
  done
}

secrets_dir() {
  if [[ -n "$SECRETS_DIR_OVERRIDE" ]]; then
    echo "$SECRETS_DIR_OVERRIDE"
  else
    # Default: a `secrets/` dir alongside (one level up from) the flake dir, so
    # it stays OUTSIDE the flake's store closure. eval reads the pubkey via the
    # SBC_DEPLOY_PUBKEY_FILE env var + `--impure` (see ssh-deploy.nix), which
    # keeps the private half from ever being copied into /nix/store.
    echo "$(repo_root)/${FLAKE_SUBDIR%/}/../secrets"
  fi
}

# Path for a persistent GC-root out-link, under a gitignored dir in the source
# tree. Rooting a build's output keeps its WHOLE closure alive through Nix
# garbage collection — crucially the config-specific derivations (the image, the
# app, root-authorized_keys, the systemd/NetworkManager units) that live in NO
# binary cache. Without a root (`--no-link`) those outputs are unrooted, Nix's GC
# (aggressive under Determinate) reaps them, and every "already built" re-run has
# to rebuild them on the linux builder. With the root, an unchanged re-run
# rebuilds nothing and doesn't touch the builder at all. Name is per project+attr
# so distinct targets (image_sd vs image_sd_base) don't clobber each other.
gc_root_link() {
  local dir; dir="$(repo_root)/.sbc-build"
  mkdir -p "$dir"
  echo "$dir/${PROJECT}.$(printf '%s' "$1" | tr '/.' '__')"
}

# ---------------------------------------------------------------------------
# keys — deploy SSH key management (ed25519 pair).
# ---------------------------------------------------------------------------
key_paths() {
  SECRETS="$(secrets_dir)"
  PRIV="$SECRETS/deploy_key"
  PUB="$SECRETS/deploy_key.pub"
}

keys_init() {
  key_paths
  mkdir -p "$SECRETS"; chmod 700 "$SECRETS"
  if [[ -f "$PRIV" ]]; then
    echo "Deploy key already exists at $PRIV (use 'rotate' to replace)." >&2
    return 0
  fi
  ssh-keygen -t ed25519 -N "" -C "${PROJECT}-deploy" -f "$PRIV"
  chmod 600 "$PRIV"; chmod 644 "$PUB"
  echo "Generated deploy key:"; echo "  private: $PRIV"; echo "  public : $PUB"
}

keys_ensure() { key_paths; [[ -f "$PUB" ]] || keys_init; }

keys_rotate() {
  key_paths
  if [[ -f "$PRIV" ]]; then
    # Timestamp comes from `date`; harmless for a backup suffix.
    ts="$(date +%Y%m%d%H%M%S)"
    mv "$PRIV" "$PRIV.bak.$ts"
    [[ -f "$PUB" ]] && mv "$PUB" "$PUB.bak.$ts"
    echo "Backed up old key with suffix .bak.$ts" >&2
  fi
  keys_init
  cat >&2 <<EOF

Rotation complete. To finish rotating a FIELDED board:
  1. Re-image it (the *.image_sd target), OR
  2. While you still have access with the OLD key, run the *.deploy_live target
     (the new pubkey is baked into the rebuilt config), then remove the old key
     from the board's root authorized_keys.
EOF
}

cmd_keys() {
  local action="${POSITIONAL[0]:-}"
  case "$action" in
    init)   keys_init ;;
    ensure) keys_ensure ;;
    rotate) keys_rotate ;;
    path)   key_paths; echo "private: $PRIV"; echo "public : $PUB" ;;
    pub)    key_paths; cat "$PUB" ;;
    *) echo "usage: keys {init|ensure|rotate|path|pub}" >&2; exit 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# image — build the SD image and optionally flash it.
# ---------------------------------------------------------------------------
cmd_image() {
  [[ -n "$FLAKE_SUBDIR" ]] || die "--flake-subdir not set (the sbc_deploy macro sets this)."
  command -v nix >/dev/null 2>&1 || die "'nix' not found. Build the image on a host with Nix (flakes enabled)."

  local flake_dir; flake_dir="$(repo_root)/$FLAKE_SUBDIR"
  key_paths

  echo "==> Ensuring deploy SSH key exists (public half is baked into the image)"
  keys_ensure

  # ssh-deploy.nix reads the pubkey from this absolute path at eval time; --impure
  # lets eval reach it (the key lives outside the flake root on purpose).
  export SBC_DEPLOY_PUBKEY_FILE="$PUB"

  # --hostname overrides the flake's baked-in networking.hostName for this build,
  # so one config can be flashed onto several boards (e.g. hitl-rig-2). flake.nix
  # reads $SBC_HOSTNAME_OVERRIDE at eval (--impure); empty => the flake default.
  if [[ -n "$HOSTNAME_ATTR" ]]; then
    echo "==> Overriding hostname: $HOSTNAME_ATTR"
    export SBC_HOSTNAME_OVERRIDE="$HOSTNAME_ATTR"
  fi

  prepare_backend "path:${flake_dir}#${IMAGE_ATTR}"

  echo "==> Building SD image: path:${flake_dir}#${IMAGE_ATTR}"
  # Capture the store output path from --print-out-paths (stdout); build progress
  # stays on stderr. Avoids `readlink -f`, which BSD/macOS doesn't support.
  # ${arr[@]+…} guards the empty-array-under-`set -u` case on bash 3.2 (macOS).
  local out img gclink
  gclink="$(gc_root_link "$IMAGE_ATTR")"
  out="$(nix build \
    ${FRAMEWORK_ARGS[@]+"${FRAMEWORK_ARGS[@]}"} \
    ${BUILDER_ARGS[@]+"${BUILDER_ARGS[@]}"} \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
    --impure --out-link "$gclink" --print-out-paths \
    "path:${flake_dir}#${IMAGE_ATTR}" | tail -n1)"
  [[ -n "$out" ]] || die "nix build produced no output path."
  # The output is a DIRECTORY (itself named …img.zst); the actual image is a file
  # inside it (e.g. sd-image/*.img.zst) — restrict to -type f so we don't pick
  # the directory.
  img="$(find "$out" -maxdepth 2 -type f \( -name '*.img' -o -name '*.img.zst' \) | head -n1)"
  [[ -n "$img" ]] || die "no .img/.img.zst file found under $out."
  echo "==> Built image: $img"

  if [[ $WRITE -eq 0 || -z "$DEVICE" ]]; then
    echo "Not writing to a device. Re-run with --device to flash, e.g.:"
    echo "  Linux:  bazel run … -- --device /dev/sdX"
    echo "  macOS:  diskutil list   # find the card, then --device /dev/diskN"
    return 0
  fi

  flash_image "$img" "$DEVICE"
}

# Stream the image bytes to stdout, decompressing .zst on the fly and, when pv is
# available, through pv for a progress bar/ETA. pv reads the (compressed) file
# directly so it auto-sizes the bar.
stream_image() {
  local img="$1" pv="$2" zstd="$3" have_pv="$4"
  if [[ "$have_pv" == 1 ]]; then
    if [[ "$img" == *.zst ]]; then "$pv" "$img" | "$zstd" -dc; else "$pv" "$img"; fi
  else
    if [[ "$img" == *.zst ]]; then "$zstd" -dc "$img"; else cat "$img"; fi
  fi
}

# Write an image (raw or .zst) to a block device, cross-platform (Linux + macOS).
flash_image() {
  local img="$1" device="$2"
  local os; os="$(uname -s)"

  # Prefer the bundled tools (SBC_ZSTD/SBC_PV, from the launcher), else PATH.
  local zstd="${SBC_ZSTD:-zstd}" pv="${SBC_PV:-pv}"
  if [[ "$img" == *.zst ]]; then
    command -v "$zstd" >/dev/null 2>&1 \
      || die "zstd not found to decompress the image. Install it (nix profile install nixpkgs#zstd, or brew/apt install zstd)."
  fi
  local have_pv=0
  command -v "$pv" >/dev/null 2>&1 && have_pv=1

  echo "!!  About to OVERWRITE $device with the $PROJECT image."
  if [[ "$os" == "Darwin" ]]; then diskutil list "$device" || true; else lsblk "$device" || true; fi
  read -r -p "Type the device path again to confirm ($device): " confirm
  [[ "$confirm" == "$device" ]] || die "Mismatch; aborting."

  if [[ "$os" == "Darwin" ]]; then
    # Unmount (not eject) so the raw device stays open; write to the raw node
    # (/dev/rdiskN) with a lowercase-suffix block size (BSD dd).
    sudo diskutil unmountDisk "$device" || true
    local rdev="/dev/r${device#/dev/}"
    echo "==> Writing to $rdev (raw)…"
    [[ $have_pv -eq 1 ]] || echo "   (no pv; press Ctrl-T for progress)"
    stream_image "$img" "$pv" "$zstd" "$have_pv" | sudo dd of="$rdev" bs=4m
    sync
    sudo diskutil eject "$device" || true
  else
    echo "==> Writing to $device…"
    if [[ $have_pv -eq 1 ]]; then
      # pv shows the progress bar; keep dd quiet but flush at the end.
      stream_image "$img" "$pv" "$zstd" "$have_pv" | sudo dd of="$device" bs=4M conv=fsync
    else
      stream_image "$img" "$pv" "$zstd" "$have_pv" | sudo dd of="$device" bs=4M status=progress conv=fsync
    fi
    sync
  fi
  echo "==> Done. Insert the card into the board and boot."
}

# ---------------------------------------------------------------------------
# deploy — in-place upgrade of a running board. Rather than run nixos-rebuild
# (a Linux tool that's awkward on macOS), do the three steps it does with
# darwin-native tooling: build the system closure with `nix build` (dispatched
# to the linux builder like image builds), `nix copy` it to the board, then
# activate it over SSH. Works uniformly from Linux and macOS.
# ---------------------------------------------------------------------------
cmd_deploy() {
  [[ -n "$FLAKE_SUBDIR" ]] || die "--flake-subdir not set (the sbc_deploy macro sets this)."
  DEPLOY_HOST="${POSITIONAL[0]:-}"
  [[ -n "$DEPLOY_HOST" ]] || { echo "usage: deploy_live <host-or-ip> [--user root]" >&2; exit 2; }
  command -v nix >/dev/null 2>&1 || die "'nix' not found."
  command -v ssh >/dev/null 2>&1 || die "'ssh' not found."

  local flake_dir attr target
  flake_dir="$(repo_root)/$FLAKE_SUBDIR"
  attr="${HOSTNAME_ATTR:-$PROJECT}"
  key_paths
  [[ -f "$PRIV" ]] || die "deploy private key not found at $PRIV. Generate it (and image/deploy the board to trust it) with the .keys target: keys init"
  chmod 600 "$PRIV" 2>/dev/null || true

  target="${DEPLOY_USER}@${DEPLOY_HOST}"
  local ssh_opts="-i $PRIV -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  export NIX_SSHOPTS="$ssh_opts"          # used by `nix copy` over ssh-ng
  export SBC_DEPLOY_PUBKEY_FILE="$PUB"     # baked into the config at eval (--impure)

  prepare_backend "path:${flake_dir}#nixosConfigurations.${attr}.config.system.build.toplevel"

  # 1. Build the system closure (aarch64-linux; goes to the linux builder).
  echo "==> Building system closure: path:${flake_dir}#nixosConfigurations.${attr}"
  local toplevel gclink
  gclink="$(gc_root_link "${attr}.toplevel")"
  toplevel="$(nix build \
    ${FRAMEWORK_ARGS[@]+"${FRAMEWORK_ARGS[@]}"} \
    ${BUILDER_ARGS[@]+"${BUILDER_ARGS[@]}"} \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
    --impure --out-link "$gclink" --print-out-paths \
    "path:${flake_dir}#nixosConfigurations.${attr}.config.system.build.toplevel" | tail -n1)"
  [[ -n "$toplevel" ]] || die "failed to build the system closure."
  echo "==> Built $toplevel"

  # 2. Copy the closure to the board (root is a trusted user there).
  echo "==> Copying closure to $target"
  nix copy --no-check-sigs --to "ssh-ng://${target}" "$toplevel"

  # 3. Register it as the current system generation and activate it.
  echo "==> Activating on $target (switch-to-configuration switch)"
  # shellcheck disable=SC2086
  ssh $ssh_opts "$target" \
    "nix-env -p /nix/var/nix/profiles/system --set '$toplevel' && '$toplevel/bin/switch-to-configuration' switch"
  echo "==> Switch complete on $DEPLOY_HOST."
}

# ---------------------------------------------------------------------------
# ssh — open a shell on the board using the deploy key. Host defaults to
# <hostName>.local (mDNS); override with a positional host/IP. Extra args after
# `--` are forwarded to ssh (e.g. a remote command).
# ---------------------------------------------------------------------------
cmd_ssh() {
  command -v ssh >/dev/null 2>&1 || die "'ssh' not found."
  key_paths
  [[ -f "$PRIV" ]] || die "deploy private key not found at $PRIV. Generate it with the .keys target (keys init) and image/deploy the board first."
  chmod 600 "$PRIV" 2>/dev/null || true

  local host target
  host="${POSITIONAL[0]:-}"
  [[ -n "$host" ]] || host="${HOSTNAME_ATTR:-$PROJECT}.local"
  target="${DEPLOY_USER}@${host}"

  echo "==> ssh $target (deploy key: $PRIV)" >&2
  exec ssh -i "$PRIV" \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=accept-new \
    "$target" \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
}

# ---------------------------------------------------------------------------
# builder — start the sized-up linux-builder VM (macOS). Long-running; leave it
# up in its terminal. Needs the framework in-tree (--framework-subdir).
# ---------------------------------------------------------------------------
cmd_builder() {
  command -v nix >/dev/null 2>&1 || die "'nix' not found."
  [[ -n "$FRAMEWORK_SUBDIR" ]] || die "--framework-subdir not set; the linux-builder target needs sbc-deploy's nix/ in the source tree."
  local bflake; bflake="$(repo_root)/${FRAMEWORK_SUBDIR%/}/builder"
  [[ -f "$bflake/flake.nix" ]] || die "builder flake not found at $bflake."
  echo "==> Starting linux-builder VM from path:$bflake (leave running; 'shutdown now' in its console, or Ctrl-C, to stop)"
  exec nix run ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "path:${bflake}#linux-builder"
}

# ---------------------------------------------------------------------------
# cache — start the harmonia binary cache (serves the local nix store). Long-
# running; leave it up while building. Needs the framework in-tree.
# ---------------------------------------------------------------------------
cmd_cache() {
  command -v nix >/dev/null 2>&1 || die "'nix' not found."
  [[ -n "$FRAMEWORK_SUBDIR" ]] || die "--framework-subdir not set; the cache target needs sbc-deploy's nix/ in the source tree."
  local cflake; cflake="$(repo_root)/${FRAMEWORK_SUBDIR%/}/cache"
  [[ -f "$cflake/flake.nix" ]] || die "cache flake not found at $cflake."
  echo "==> Starting harmonia binary cache from path:$cflake (leave running; Ctrl-C to stop)"
  exec nix run ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "path:${cflake}#cache"
}

# --- dispatch ---------------------------------------------------------------
POSITIONAL=()
parse_common_flags "$@"

# Super-lean base image: the flake reads $SBC_LEAN at eval (--impure). Exported
# for image/deploy; harmless for keys/ssh/builder (no nix eval of the image).
[[ -n "$LEAN" ]] && export SBC_LEAN=1

case "$SUBCMD" in
  keys)    cmd_keys ;;
  image)   cmd_image ;;
  deploy)  cmd_deploy ;;
  ssh)     cmd_ssh ;;
  builder) cmd_builder ;;
  cache)   cmd_cache ;;
  ""|-h|--help)
    cat >&2 <<EOF
sbc-deploy: usage via the Bazel targets created by the sbc_application macro:
  bazel run //path:NAME.image_sd      -- [--device /dev/sdX] [--no-write] [--hostname <name>] [--builder <spec> | --cross] [--keep-builder]
  bazel run //path:NAME.image_sd_base -- [--device /dev/sdX] [--no-write] [--hostname <name>] [--builder <spec> | --cross] [--keep-builder]
  bazel run //path:NAME.deploy_live   -- <host-or-ip> [--user root] [--builder <spec> | --cross] [--keep-builder]
  bazel run //path:NAME.ssh           -- [host-or-ip] [--user root] [-- <ssh args>]
  bazel run //path:NAME.keys          -- {init|ensure|rotate|path|pub}

On aarch64-darwin (Apple Silicon) an image can't be built natively. By DEFAULT
the build auto-manages a sized aarch64-linux builder VM: it boots one on demand
(only when something actually needs building — a fully-cached re-run touches no
builder), dispatches the build, copies the result into your local /nix/store,
and shuts the VM down afterwards. Fully zero-conf: no sudo, no /etc/nix changes
(it boots with its own key under ~/.config/sbc-deploy). --keep-builder leaves the
VM running for fast iteration. Alternatively pass --builder <spec> to use your
own aarch64-linux builder, or --cross to cross-compile locally (no builder, but
rebuilds from source; best on x86_64-linux). See the README.
EOF
    exit 2 ;;
  *) die "unknown subcommand '$SUBCMD' (expected image|deploy|ssh|keys|builder|cache)" ;;
esac
