{
  # hello-sbc — the smallest useful sbc-deploy consumer.
  #
  # Depends on the sbc-deploy framework flake for board support + the reusable
  # modules, declares one placeholder application, and exposes the SD image the
  # `:hello.image_sd` Bazel target builds. A real project swaps the placeholder
  # for its own package(s) and adds hardware modules (e.g. sbc-deploy's spi.nix)
  # as needed.
  description = "hello-sbc — minimal sbc-deploy example";

  inputs = {
    # The framework flake lives in this repo's nix/ subdir. This is exactly how
    # an external consumer references it. When developing sbc-deploy itself
    # against an un-pushed local checkout, override at build time, e.g.:
    #   bazel run //examples/hello-sbc:hello.image_sd -- --no-write \
    #       -- --override-input sbc-deploy path:/abs/path/to/sbc-deploy/nix
    # (everything after the second `--` is forwarded verbatim to `nix build`).
    sbc-deploy.url = "github:fughilli/sbc-deploy?dir=nix";
  };

  # mkSbcProject returns the full output set for all three deployment modes:
  #   images.sdImage       — base + app          (hello.image_sd)
  #   images.sdImageBase   — base only           (hello.image_sd_base)
  #   nixosConfigurations.hello / hello-base      (hello.deploy_live)
  # `appModules` land only in the full image/config; `systemModules` (networking,
  # hardware) are baked into both so the base image can be reached for deploy.
  outputs = { self, sbc-deploy, ... }:
    sbc-deploy.lib.mkSbcProject {
      hostName = "hello";
      board = "raspberry-pi-5";
      appModules = [ ./hello-app.nix ];
      systemModules = [ ./network.nix ];
    };
}
