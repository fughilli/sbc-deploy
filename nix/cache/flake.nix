{
  # sbc-deploy — a restartable binary cache (harmonia) that serves the local
  # nix store over HTTP.
  #
  #   bazel run //:cache          # or: nix run '…?dir=nix/cache#cache'
  #
  # Run it on the machine whose store holds your build artifacts (the Mac). It
  # serves that store, so cached paths — notably the compiled Raspberry Pi
  # kernel — survive stopping/recreating the linux-builder VM: the next build
  # substitutes them from here instead of recompiling. The store persists on
  # disk; only the harmonia process is start/stop (Ctrl-C to stop, re-run to
  # restart). A signing key is generated once and kept under
  # $XDG_CONFIG_HOME/sbc-deploy (persistent); its public half is printed for you
  # to add to nix.conf `trusted-public-keys`.
  #
  # Binds to all interfaces so a QEMU linux-builder VM can reach it at the host
  # gateway (http://10.0.2.2:PORT). The served store is read-only and NAR-signed;
  # still, only expose it on networks you trust.

  description = "sbc-deploy — restartable harmonia binary cache serving the local nix store";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems f;

      runnerFor = system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in pkgs.writeShellApplication {
          name = "sbc-cache";
          runtimeInputs = [ pkgs.harmonia pkgs.nix pkgs.coreutils ];
          text = ''
            port="''${SBC_CACHE_PORT:-5000}"
            keydir="''${SBC_CACHE_KEYDIR:-''${XDG_CONFIG_HOME:-$HOME/.config}/sbc-deploy}"
            secret="$keydir/cache-secret.key"
            public="$keydir/cache-public.key"

            mkdir -p "$keydir"; chmod 700 "$keydir"
            if [[ ! -f "$secret" ]]; then
              echo "==> Generating cache signing key -> $secret" >&2
              nix key generate-secret --key-name "sbc-deploy-cache-1" > "$secret"
              nix key convert-secret-to-public < "$secret" > "$public"
              chmod 600 "$secret"
            fi

            echo "==> Cache public key (add to nix.conf trusted-public-keys):" >&2
            echo >&2; cat "$public" >&2; echo >&2

            config="$(mktemp -t sbc-cache.XXXXXX)"
            # Lower priority number = preferred over cache.nixos.org (40).
            printf 'bind = "[::]:%s"\npriority = 30\n' "$port" > "$config"

            echo "==> harmonia serving the local nix store on port $port" >&2
            echo "    local:   http://localhost:$port" >&2
            echo "    from VM: http://10.0.2.2:$port   (QEMU host gateway)" >&2
            echo "    (Ctrl-C to stop; re-run to restart)" >&2
            CONFIG_FILE="$config" SIGN_KEY_PATHS="$secret" HOME="$HOME" exec harmonia
          '';
        };
    in
    {
      apps = forAll (system:
        let r = runnerFor system; in {
          cache = { type = "app"; program = "${r}/bin/sbc-cache"; };
          default = { type = "app"; program = "${r}/bin/sbc-cache"; };
        });

      packages = forAll (system:
        let r = runnerFor system; in {
          sbc-cache = r;
          default = r;
        });
    };
}
