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

  outputs = { self, sbc-deploy, ... }: {
    nixosConfigurations.hello = sbc-deploy.lib.mkSbcSystem {
      hostName = "hello";
      board = "raspberry-pi-5";
      modules = [ ./hello-app.nix ];
    };

    # The deploy targets read this attribute (`--attr images.sdImage`).
    images.sdImage =
      self.nixosConfigurations.hello.config.system.build.sdImage;
  };
}
