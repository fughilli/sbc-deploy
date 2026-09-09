# hello-sbc deploy secrets

The deploy SSH key pair for this example lives here, generated on demand by:

```sh
bazel run //examples/hello-sbc:hello.keys -- init
```

- `deploy_key` (private) — used by `hello.deploy_live`; **never committed**.
- `deploy_key.pub` (public) — baked into the image's root `authorized_keys`.

Everything in this directory except this README is gitignored (see the repo
root `.gitignore`). To keep keys outside the repo entirely, set
`SBC_DEPLOY_KEY_DIR=/path/to/keys` before running the targets.
