# sbc-deploy

A framework for deploying packaged applications to single-board computers
(Raspberry Pi and friends) using Bazel + Nix.

## Status

Early bring-up. This repo is being developed standalone as a reusable module,
extracted from the deployment tooling that currently lives under `pi/` in the
[`splanc`](https://github.com/fughilli/splanc) repo. Once it works here it will
be vendored back into that project.

## Goals

- Reproducible, hermetic builds of application bundles (Bazel + Nix).
- Push-button deploy of those bundles to one or more SBCs.
- Reusable across projects — no `splanc`-specific assumptions baked in.

## Layout

_TBD as the module takes shape._
