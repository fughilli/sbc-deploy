{
  # hello-amd64 — the smallest useful sbc-deploy consumer for an amd64 mini PC.
  #
  # Identical in shape to examples/hello-sbc, but `family = "x86_64"` selects the
  # amd64 system builder (stock nixpkgs, UEFI/systemd-boot) so mkSbcProject
  # exposes a bootable install USB (images.installerIso) instead of an SD image.
  description = "hello-amd64 — minimal amd64 sbc-deploy example";

  inputs = {
    # The framework flake lives in this repo's nix/ subdir. When developing
    # sbc-deploy itself against an un-pushed local checkout, override at build
    # time (the Bazel `framework = "nix"` attr does this automatically):
    #   bazel run //examples/hello-amd64:hello.image_installer -- --no-write \
    #       -- --override-input sbc-deploy path:/abs/path/to/sbc-deploy/nix
    sbc-deploy.url = "github:fughilli/sbc-deploy?dir=nix";
  };

  # mkSbcProject returns the full output set:
  #   images.installerIso      — install USB, base + app     (hello.image_installer)
  #   images.installerIsoBase  — install USB, base only      (hello.image_installer_base)
  #   nixosConfigurations.hello-amd64 / -base                (hello.deploy_live)
  outputs = { self, sbc-deploy, ... }:
    sbc-deploy.lib.mkSbcProject {
      hostName = "hello-amd64";
      # The amd64 family. Also flows in from Bazel via the sbc_application `board`
      # attribute ($SBC_BOARD_FAMILY), so a Bazel-driven build needn't set it
      # here; kept explicit so a direct-Nix `nix build` picks the right builder.
      family = "x86_64";
      appModules = [ ./hello-app.nix ];
      systemModules = [ ./network.nix ];
    };
}
