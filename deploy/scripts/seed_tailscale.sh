#!/usr/bin/env bash
# Seed Tailscale credentials onto a running SBC — bring the node up on your
# tailnet via `tailscale up --authkey` over the deploy SSH. The auth key is never
# written to git or the nix store. Requires `sbcDeploy.tailscale.enable = true`
# in the image (see nix/modules/tailscale.nix), deployed to the board. tailscaled
# persists its node key under /var/lib/tailscale, so this is a one-time step —
# membership survives reboots and redeploys without re-seeding.
#
#   seed_tailscale.sh --host H [--ssh-key K] [--user root] --authkey tskey-… \
#       [--hostname NAME] [--ssh] [-- <extra `tailscale up` flags>]
#   seed_tailscale.sh --host H [--ssh-key K] --status
#   seed_tailscale.sh --host H [--ssh-key K] --down
set -euo pipefail

HOST="" SSH_KEY="" USER="root" AUTHKEY="" TSNAME="" TS_SSH="no" ACTION="up"
EXTRA=()

die() { echo "seed_tailscale: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)     HOST="$2"; shift 2 ;;
    --ssh-key)  SSH_KEY="$2"; shift 2 ;;
    --user)     USER="$2"; shift 2 ;;
    --authkey)  AUTHKEY="$2"; shift 2 ;;
    --hostname) TSNAME="$2"; shift 2 ;;
    --ssh)      TS_SSH="yes"; shift ;;
    --status)   ACTION="status"; shift ;;
    --down)     ACTION="down"; shift ;;
    --)         shift; EXTRA+=("$@"); break ;;
    -h|--help)  sed -n '2,15p' "$0"; exit 0 ;;
    *)          die "unknown arg: $1" ;;
  esac
done

[ -n "$HOST" ] || die "--host is required"
SSH=(ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[ -n "$SSH_KEY" ] && SSH+=(-i "$SSH_KEY")
remote() { "${SSH[@]}" "$USER@$HOST" "$@"; }

case "$ACTION" in
  status)
    remote "tailscale status" || die "couldn't get status (is tailscale enabled + deployed?)"
    ;;
  down)
    echo "bringing tailscale DOWN on $HOST"
    remote "tailscale down"
    ;;
  up)
    [ -n "$AUTHKEY" ] || die "--authkey tskey-… is required for bring-up"
    # Build the remote command; quote each value for the remote shell. The
    # hostname defaults (on the device) to networking.hostName, which is the board
    # identity, so --hostname is only needed to override it.
    up="tailscale up --authkey $(printf %q "$AUTHKEY")"
    [ -n "$TSNAME" ] && up="$up --hostname $(printf %q "$TSNAME")"
    [ "$TS_SSH" = "yes" ] && up="$up --ssh"
    for f in ${EXTRA[@]+"${EXTRA[@]}"}; do up="$up $(printf %q "$f")"; done
    echo "bringing $HOST up on the tailnet…"
    remote "$up" || die "tailscale up failed (is sbcDeploy.tailscale.enable set and deployed to the board?)"
    echo "---- tailscale status ----"
    remote "tailscale status" || true
    echo "done."
    ;;
esac
