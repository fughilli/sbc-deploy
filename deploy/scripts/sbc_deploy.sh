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
# Requires `nix` (with flakes) / `nixos-rebuild` on the host actually running a
# build or deploy. `keys` needs only ssh-keygen.
set -euo pipefail

# Runs under the nixpkgs-vendored bash via launch.sh (see deploy/defs.bzl).
# Set SBC_DEBUG=1 to confirm which interpreter is in use.
[[ -n "${SBC_DEBUG:-}" ]] && echo "sbc-deploy: bash=${BASH:-?} ${BASH_VERSION:-?}" >&2

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
EXTRA_ARGS=()

die() { echo "ERROR: $*" >&2; exit 1; }

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
      --secrets-dir)  SECRETS_DIR_OVERRIDE="$2"; shift 2 ;;
      --device)          DEVICE="$2"; shift 2 ;;
      --no-write|--no_write) WRITE=0; shift ;;
      --user)            DEPLOY_USER="$2"; shift 2 ;;
      --)                # everything after `--` is forwarded verbatim to nix
                         shift
                         while [[ $# -gt 0 ]]; do EXTRA_ARGS+=("$1"); shift; done ;;
      -*)                die "unrecognized option '$a'. Recognized: --device <dev>, --no-write, --user <name>. To pass flags to nix/nixos-rebuild, put them after a literal '--' (e.g. '-- -- --dry-run')." ;;
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

  echo "==> Building SD image: path:${flake_dir}#${IMAGE_ATTR}"
  # ${arr[@]+…} guards the empty-array-under-`set -u` case on bash 3.2 (macOS).
  nix build ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
    --impure \
    --print-out-paths \
    "path:${flake_dir}#${IMAGE_ATTR}" \
    --out-link /tmp/sbc-image-"$PROJECT"
  local out img
  out="$(readlink -f /tmp/sbc-image-"$PROJECT")"
  img="$(find "$out" -maxdepth 2 \( -name '*.img' -o -name '*.img.zst' \) | head -n1)"
  echo "==> Built image: $img"

  if [[ $WRITE -eq 0 || -z "$DEVICE" ]]; then
    echo "Not writing to a device (pass --device /dev/sdX to flash)."
    echo "To flash manually:"
    echo "  zstdcat '$img' | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync"
    return 0
  fi

  echo "!!  About to OVERWRITE $DEVICE with the $PROJECT image."
  lsblk "$DEVICE" || true
  read -r -p "Type the device path again to confirm ($DEVICE): " confirm
  [[ "$confirm" == "$DEVICE" ]] || die "Mismatch; aborting."
  if [[ "$img" == *.zst ]]; then
    zstdcat "$img" | sudo dd of="$DEVICE" bs=4M status=progress conv=fsync
  else
    sudo dd if="$img" of="$DEVICE" bs=4M status=progress conv=fsync
  fi
  sync
  echo "==> Done. Insert the card into the board and boot."
}

# ---------------------------------------------------------------------------
# deploy — in-place upgrade of a running board via nixos-rebuild --target-host.
# ---------------------------------------------------------------------------
cmd_deploy() {
  [[ -n "$FLAKE_SUBDIR" ]] || die "--flake-subdir not set (the sbc_deploy macro sets this)."
  DEPLOY_HOST="${POSITIONAL[0]:-}"
  [[ -n "$DEPLOY_HOST" ]] || { echo "usage: deploy_live <host-or-ip> [--user root] [nix args]" >&2; exit 2; }
  command -v nixos-rebuild >/dev/null 2>&1 || die "'nixos-rebuild' not found. Deploy from a host with Nix/NixOS tooling."

  local flake_dir attr target
  flake_dir="$(repo_root)/$FLAKE_SUBDIR"
  attr="${HOSTNAME_ATTR:-$PROJECT}"
  key_paths
  [[ -f "$PRIV" ]] || die "deploy private key not found at $PRIV. Generate it (and re-image to trust it) with the .keys target: keys init"
  chmod 600 "$PRIV" 2>/dev/null || true

  target="${DEPLOY_USER}@${DEPLOY_HOST}"
  export NIX_SSHOPTS="-i $PRIV -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  export SBC_DEPLOY_PUBKEY_FILE="$PUB"

  echo "==> Deploying path:${flake_dir}#${attr} to $target (in-place switch)"
  nixos-rebuild switch \
    --flake "path:${flake_dir}#${attr}" \
    --target-host "$target" \
    --use-remote-sudo \
    --impure \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
  echo "==> Switch complete on $DEPLOY_HOST."
}

# --- dispatch ---------------------------------------------------------------
POSITIONAL=()
parse_common_flags "$@"

case "$SUBCMD" in
  keys)   cmd_keys ;;
  image)  cmd_image ;;
  deploy) cmd_deploy ;;
  ""|-h|--help)
    cat >&2 <<EOF
sbc-deploy: usage via the Bazel targets created by the sbc_deploy macro:
  bazel run //path:NAME.image_sd    -- [--device /dev/sdX] [--no-write]
  bazel run //path:NAME.deploy_live -- <host-or-ip> [--user root]
  bazel run //path:NAME.keys        -- {init|ensure|rotate|path|pub}
EOF
    exit 2 ;;
  *) die "unknown subcommand '$SUBCMD' (expected image|deploy|keys)" ;;
esac
