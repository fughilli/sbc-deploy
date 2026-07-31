#!/usr/bin/env bash
# Seed extra WiFi networks onto a running SBC as a *persistent* layer, composed
# on top of the baked-in networks — without a rebuild/redeploy.
#
# Two layers (see nix/modules/wifi.nix):
#   baked  — sbcDeploy.wifi.networks / wifi.yaml → ensureProfiles → ephemeral
#            /run/NetworkManager/system-connections, regenerated from the config
#            every boot.
#   seeded — this script → nmcli → persistent /etc/NetworkManager/system-connections,
#            provisioned out of band (never in git or the nix store). Untouched by
#            switch-to-configuration, so a redeploy never clobbers it.
#
# NetworkManager loads both dirs and picks by autoconnect-priority. Seeded
# profiles are named `seed-<ssid>` so they're easy to list/remove.
#
#   seed_wifi.sh --host H [--ssh-key K] [--user root] \
#       ( --ssid SSID --psk PSK [--priority N] [--hidden] | --file NETWORKS.yaml )
#   seed_wifi.sh --host H --list
#   seed_wifi.sh --host H --remove SSID
set -euo pipefail

HOST="" SSH_KEY="" USER="root"
SSID="" PSK="" PRIORITY="" HIDDEN="no" FILE="" ACTION="add" REMOVE_SSID=""

die() { echo "seed_wifi: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)     HOST="$2"; shift 2 ;;
    --ssh-key)  SSH_KEY="$2"; shift 2 ;;
    --user)     USER="$2"; shift 2 ;;
    --ssid)     SSID="$2"; shift 2 ;;
    --psk)      PSK="$2"; shift 2 ;;
    --priority) PRIORITY="$2"; shift 2 ;;
    --hidden)   HIDDEN="yes"; shift ;;
    --file)     FILE="$2"; shift 2 ;;
    --list)     ACTION="list"; shift ;;
    --remove)   ACTION="remove"; REMOVE_SSID="$2"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *)          die "unknown arg: $1" ;;
  esac
done

[ -n "$HOST" ] || die "--host is required"
# -n: never read stdin, so ssh inside a `while read` loop doesn't slurp the list.
SSH=(ssh -n -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[ -n "$SSH_KEY" ] && SSH+=(-i "$SSH_KEY")
remote() { "${SSH[@]}" "$USER@$HOST" "$@"; }

# nmcli add for one network. Profile name seed-<ssid>; recreated idempotently.
seed_one() {
  local ssid="$1" psk="$2" prio="${3:-50}" hidden="${4:-no}"
  [ -n "$ssid" ] || die "network missing ssid"
  local args="type wifi con-name 'seed-$ssid' ssid '$ssid' connection.autoconnect-priority $prio ipv4.method auto ipv6.method auto"
  [ "$hidden" = "yes" ] && args="$args wifi.hidden yes"
  if [ -n "$psk" ]; then
    args="$args wifi-sec.key-mgmt wpa-psk wifi-sec.psk '$psk'"
  fi
  local note=""; [ "$hidden" = "yes" ] && note=", hidden"
  local sec=", open"; [ -n "$psk" ] && sec=", wpa-psk"
  echo "  seeding '$ssid' (priority $prio$sec$note)"
  # Replace any existing same-named profile so re-seeding updates the psk.
  remote "nmcli -t connection delete 'seed-$ssid' >/dev/null 2>&1 || true; nmcli connection add $args >/dev/null && echo '    ok'"
}

case "$ACTION" in
  list)
    echo "seeded WiFi profiles on $HOST:"
    remote "nmcli -f NAME,TYPE,AUTOCONNECT-PRIORITY connection show | awk 'NR==1 || /^seed-/'"
    ;;
  remove)
    [ -n "$REMOVE_SSID" ] || die "--remove needs an SSID"
    echo "removing seed-$REMOVE_SSID from $HOST"
    remote "nmcli connection delete 'seed-$REMOVE_SSID'"
    ;;
  add)
    if [ -n "$FILE" ]; then
      [ -f "$FILE" ] || die "no such file: $FILE"
      echo "seeding networks from $FILE onto $HOST"
      # Parse the wifi.yaml schema (list of {ssid,psk?,priority?,hidden?}) into
      # TSV without a YAML dep: prefer PyYAML, fall back to a minimal parser.
      # \x1f (unit separator) delimits fields: unlike tab it isn't whitespace-IFS,
      # so an empty psk (open network) doesn't collapse and shift columns.
      python3 - "$FILE" <<'PY' | while IFS=$'\x1f' read -r ssid psk prio hidden; do
import sys
def minimal(text):
    nets, cur = [], None
    for raw in text.splitlines():
        line = raw.split('#', 1)[0].rstrip()
        if not line.strip():
            continue
        stripped = line.strip()
        if stripped.startswith('- '):
            if cur is not None: nets.append(cur)
            cur = {}
            stripped = stripped[2:].strip()
        if ':' in stripped and cur is not None:
            k, _, v = stripped.partition(':')
            cur[k.strip()] = v.strip().strip('"').strip("'")
    if cur: nets.append(cur)
    return nets
text = open(sys.argv[1]).read()
try:
    import yaml
    nets = yaml.safe_load(text) or []
except Exception:
    nets = minimal(text)
for n in nets:
    if not isinstance(n, dict) or not n.get('ssid'): continue
    hidden = 'yes' if str(n.get('hidden','')).lower() in ('true','yes','1') else 'no'
    print('\x1f'.join([str(n.get('ssid','')), str(n.get('psk','')),
                       str(n.get('priority','') or 50), hidden]))
PY
        seed_one "$ssid" "$psk" "$prio" "$hidden"
      done
    elif [ -n "$SSID" ]; then
      seed_one "$SSID" "$PSK" "${PRIORITY:-50}" "$HIDDEN"
    else
      die "give --ssid/--psk, --file, --list, or --remove"
    fi
    echo "reloading NetworkManager connections"
    remote "nmcli connection reload"
    echo "done."
    ;;
esac
