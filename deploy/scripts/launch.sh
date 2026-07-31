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

exec "$bash_bin" "$script" "$@"
