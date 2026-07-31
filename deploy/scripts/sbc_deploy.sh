#!/usr/bin/env bash
# sbc-deploy — unified entrypoint for building/flashing an SBC NixOS image,
# deploying it live, and managing the deploy SSH key.
#
# This one script backs all three Bazel targets created by the `sbc_deploy`
# macro (deploy/defs.bzl); the target bakes in the subcommand + project config
# via the sh_binary `args`, and the operator appends the rest after `--`:
#
#   bazel run //path:NAME.image_sd    -- [--device /dev/sdX] [--no-write] [nix args]
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
HOSTNAME_ATTR="${SBC_HOSTNAME:-}"      # nixosConfigurations.<attr> for deploy_live
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
      --)                # everything after `--` is forwarded verbatim to nix
                         shift
                         while [[ $# -gt 0 ]]; do EXTRA_ARGS+=("$1"); shift; done ;;
      -*)                die "unrecognized option '$a'. Recognized: --device <dev>, --no-write, --user <name>, --builder <spec>. To pass flags to nix, put them after a literal '--' (e.g. '-- -- --dry-run')." ;;
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

  set_builder_args
  set_framework_override

  echo "==> Building SD image: path:${flake_dir}#${IMAGE_ATTR}"
  # Capture the store output path from --print-out-paths (stdout); build progress
  # stays on stderr. Avoids `readlink -f`, which BSD/macOS doesn't support.
  # ${arr[@]+…} guards the empty-array-under-`set -u` case on bash 3.2 (macOS).
  local out img
  out="$(nix build \
    ${FRAMEWORK_ARGS[@]+"${FRAMEWORK_ARGS[@]}"} \
    ${BUILDER_ARGS[@]+"${BUILDER_ARGS[@]}"} \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
    --impure --no-link --print-out-paths \
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

  set_builder_args
  set_framework_override

  # 1. Build the system closure (aarch64-linux; goes to the linux builder).
  echo "==> Building system closure: path:${flake_dir}#nixosConfigurations.${attr}"
  local toplevel
  toplevel="$(nix build \
    ${FRAMEWORK_ARGS[@]+"${FRAMEWORK_ARGS[@]}"} \
    ${BUILDER_ARGS[@]+"${BUILDER_ARGS[@]}"} \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
    --impure --no-link --print-out-paths \
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
  bazel run //path:NAME.image_sd      -- [--device /dev/sdX] [--no-write] [--builder <spec>]
  bazel run //path:NAME.image_sd_base -- [--device /dev/sdX] [--no-write]
  bazel run //path:NAME.deploy_live   -- <host-or-ip> [--user root] [--builder <spec>]
  bazel run //path:NAME.ssh           -- [host-or-ip] [--user root] [-- <ssh args>]
  bazel run //path:NAME.keys          -- {init|ensure|rotate|path|pub}

On aarch64-darwin (Apple Silicon) an image can't be built locally; run the
linux-builder VM target, or pass --builder (a nix --builders spec) /
SBC_NIX_BUILDERS. See the README "Building on Apple Silicon".
EOF
    exit 2 ;;
  *) die "unknown subcommand '$SUBCMD' (expected image|deploy|ssh|keys|builder|cache)" ;;
esac
