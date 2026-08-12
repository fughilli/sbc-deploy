#!/usr/bin/env bash
# Hermetic launcher for the sbc-deploy targets.
#
# sh_binary runs a script under the interpreter named in its shebang, which on
# macOS resolves to the system bash 3.2. To avoid depending on that, the
# sbc_deploy macro points every target at THIS launcher and passes, as the two
# leading args, the runfiles paths of (1) the real script and (2) a
# nixpkgs-vendored bash. We exec that bash on the real script; everything after
# the two leading args is forwarded verbatim.
#
# This wrapper itself must stay bash-3.2 safe — it only uses the runfiles
# library and a couple of positional shifts, nothing version-specific.

# --- begin runfiles.bash initialization v3 ---
# Copied from the Bazel Bash runfiles library (tools/bash/runfiles/runfiles.bash).
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo >&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

script_rlocationpath="$1"; shift
bash_rlocationpath="$1"; shift
wifi_json_rlocationpath="$1"; shift   # "-" sentinel when no wifi config file
zstd_rlocationpath="$1"; shift        # "-" sentinel when not needed (e.g. builder)
pv_rlocationpath="$1"; shift          # "-" sentinel when not needed
board_rlocationpath="$1"; shift       # "-" sentinel when not needed (e.g. builder)
builder_rlocationpath="$1"; shift     # "-" sentinel when using --framework-subdir

script="$(rlocation "$script_rlocationpath")" || {
  echo >&2 "ERROR: could not resolve deploy script ($script_rlocationpath) in runfiles"; exit 1; }
bash_bin="$(rlocation "$bash_rlocationpath")" || {
  echo >&2 "ERROR: could not resolve nixpkgs bash ($bash_rlocationpath) in runfiles"; exit 1; }

# Declarative WiFi: the macro converted the YAML to JSON in the build graph; make
# its (absolute) runfiles path available to Nix eval via the environment.
if [[ "$wifi_json_rlocationpath" != "-" ]]; then
  SBC_WIFI_CONFIG_JSON="$(rlocation "$wifi_json_rlocationpath")" || {
    echo >&2 "ERROR: could not resolve wifi config json ($wifi_json_rlocationpath) in runfiles"; exit 1; }
  export SBC_WIFI_CONFIG_JSON
fi

# Bundled zstd for turnkey .img.zst decompression when flashing (image_sd).
if [[ "$zstd_rlocationpath" != "-" ]]; then
  SBC_ZSTD="$(rlocation "$zstd_rlocationpath")" || {
    echo >&2 "ERROR: could not resolve zstd ($zstd_rlocationpath) in runfiles"; exit 1; }
  export SBC_ZSTD
fi

# Bundled pv for a progress bar while writing the image to the card.
if [[ "$pv_rlocationpath" != "-" ]]; then
  SBC_PV="$(rlocation "$pv_rlocationpath")" || {
    echo >&2 "ERROR: could not resolve pv ($pv_rlocationpath) in runfiles"; exit 1; }
  export SBC_PV
fi

# Board definition (from the sbc_application `board` attr / an sbc_board target).
# The file is two lines: the nixos-raspberrypi board name, then comma-joined
# optional submodules. Export both for Nix eval to read (see mkSbcSystem).
if [[ "$board_rlocationpath" != "-" ]]; then
  board_file="$(rlocation "$board_rlocationpath")" || {
    echo >&2 "ERROR: could not resolve board definition ($board_rlocationpath) in runfiles"; exit 1; }
  SBC_BOARD="$(sed -n 1p "$board_file")"
  SBC_BOARD_MODULES="$(sed -n 2p "$board_file")"
  export SBC_BOARD SBC_BOARD_MODULES
fi

# The darwin linux-builder VM flake, shipped in runfiles so the auto-managed
# builder can be realised from the Bazel-pinned framework without an in-tree
# copy (see start_managed_builder). Export the resolved flake.nix path; the
# script takes its dirname as the flake dir (flake.lock sits beside it).
if [[ "$builder_rlocationpath" != "-" ]]; then
  SBC_BUILDER_FLAKE="$(rlocation "$builder_rlocationpath")" || {
    echo >&2 "ERROR: could not resolve builder flake ($builder_rlocationpath) in runfiles"; exit 1; }
  export SBC_BUILDER_FLAKE
fi

exec "$bash_bin" "$script" "$@"
