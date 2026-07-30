# hello-sbc

The smallest useful sbc-deploy consumer: one placeholder application (a trivial
HTTP server on :8080) wired up through the framework.

```sh
# From the repo root:
bazel run //examples/hello-sbc:hello.keys     -- init        # make the deploy key
bazel run //examples/hello-sbc:hello.image_sd -- --no-write  # build the SD image
bazel run //examples/hello-sbc:hello.deploy_live -- hello.local
```

Files:

- `BUILD.bazel` — calls the `sbc_deploy` macro.
- `nix/flake.nix` — depends on the framework flake, calls `mkSbcSystem`,
  exposes `images.sdImage`.
- `nix/hello-app.nix` — the app, declared via `services.sbcApps`.
- `secrets/` — gitignored deploy key material (only the README is tracked).

The flake references the framework as `github:fughilli/sbc-deploy?dir=nix`. To
build against a local, un-pushed checkout of the framework, append an override:

```sh
bazel run //examples/hello-sbc:hello.image_sd -- --no-write \
    -- --override-input sbc-deploy path:/abs/path/to/sbc-deploy/nix
```
