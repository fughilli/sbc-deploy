# Device-resident, immutable board identity.
#
# The board's hostname is its IDENTITY: everything a consumer derives per-board
# (tailscale name, AP SSID, a metrics `rig` label, …) keys off
# config.networking.hostName. That identity must be set ONCE, when the card is
# commissioned (image_sd --hostname <name>), and must then survive every later
# deploy_live unchanged — a redeploy ships new *derivation logic* (a renamed AP
# scheme, say) but must never reassign or blow away the identity itself.
#
# This module is the persistence half of that guarantee: on the first activation
# (i.e. first boot of a freshly-imaged card) it records the current hostName to a
# file OUTSIDE the Nix store, then never touches it again. The deploy script's
# other half (`deploy_live`) reads this file back off the board and rebuilds the
# closure with it, so a `deploy_live` with no --hostname can never fall back to
# the flake's baked default. See deploy/scripts/sbc_deploy.sh (cmd_deploy).
#
# Write-once is deliberate: even a closure that was (wrongly) built with the
# default hostName cannot clobber a board that already knows who it is.
{ config, lib, ... }:
{
  # Runs during switch-to-configuration, after /var is set up. Idempotent and
  # write-once: the guard means only the commissioning activation ever writes.
  system.activationScripts.sbcIdentity = lib.stringAfter [ "var" ] ''
    if [ ! -e /var/lib/sbc/hostname ]; then
      mkdir -p /var/lib/sbc
      printf '%s\n' ${lib.escapeShellArg config.networking.hostName} > /var/lib/sbc/hostname
      chmod 0644 /var/lib/sbc/hostname
    fi
  '';
}
