# SSH + deploy-key trust for passwordless first-boot deploys.
#
# The deploy flow (deploy/scripts/sbc_deploy.sh) owns one ed25519 key pair:
#   * PUBLIC half  -> baked into root's authorized_keys here, so the freshly
#                     imaged board trusts the deploy key on first boot.
#   * PRIVATE half -> stays on the operator's machine (gitignored secrets/ dir),
#                     used by the deploy_live target for
#                     `nixos-rebuild switch --target-host`.
#
# The public key text is read at NIX EVAL time. Because the modules ship from
# sbc-deploy's own store path (as a flake input), there is no reliable relative
# path back to the consumer's secrets dir — so the key path is taken from the
# env var SBC_DEPLOY_PUBKEY_FILE, which the deploy script always exports before
# `nix build --impure` / `nixos-rebuild --impure`. A consumer can also supply
# keys directly via `sbcDeploy.extraAuthorizedKeys` and skip the env entirely.
{ config, lib, pkgs, ... }:
let
  cfg = config.sbcDeploy;
  envPath = builtins.getEnv "SBC_DEPLOY_PUBKEY_FILE";

  envKey =
    if envPath != "" && builtins.pathExists (/. + envPath)
    then [ (lib.strings.trim (builtins.readFile (/. + envPath))) ]
    else [ ];

  keys = envKey ++ cfg.extraAuthorizedKeys;
in
{
  options.sbcDeploy.extraAuthorizedKeys = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Extra public keys trusted for root SSH, in addition to the one read from
      $SBC_DEPLOY_PUBKEY_FILE. Set this if you manage the deploy key yourself.
    '';
  };

  config = {
    assertions = [{
      assertion = keys != [ ];
      message = ''
        sbc-deploy: no deploy public key available.

        Set $SBC_DEPLOY_PUBKEY_FILE (the deploy_live/image_sd targets do this
        automatically after generating a key with the `.keys init` target), or
        provide sbcDeploy.extraAuthorizedKeys. Without a key the image would be
        unreachable — PasswordAuthentication is off.
      '';
    }];

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "prohibit-password"; # key-only root, for nixos-rebuild
      };
      openFirewall = true;
    };

    users.users.root.openssh.authorizedKeys.keys = keys;

    # Toolchain the remote nixos-rebuild switch needs when it shells in.
    environment.systemPackages = with pkgs; [ git rsync ];
    nix.settings.trusted-users = [ "root" ];
  };
}
