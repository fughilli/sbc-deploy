"""Public Bazel macro for wiring up an SBC application's deploy targets.

Pairs with `sbc-deploy.lib.mkSbcProject` on the Nix side, which exposes
`images.sdImage` (base + app), `images.sdImageBase` (base only), and
`nixosConfigurations.<hostName>` (full, for live switch).

Usage (in a consumer BUILD.bazel):

    load("@sbc_deploy//deploy:defs.bzl", "sbc_application")

    sbc_application(
        name = "myboard",
        flake = "path/to/nix",   # workspace-relative dir containing flake.nix
        hostname = "myboard",    # nixosConfigurations.<hostname>; default = project
        project = "myboard",     # key comment + messages; default = name
    )

This creates targets for the three deployment modes (+ key management):

    # Mode 1 — full system image (minimal system + your bundled application):
    bazel run //consumer:myboard.image_sd      -- [--device /dev/sdX] [--no-write]
    # Mode 2 — base system image only (networking, no application):
    bazel run //consumer:myboard.image_sd_base -- [--device /dev/sdX] [--no-write]
    # Mode 3 — push the application (+ its system deps) to a running board:
    bazel run //consumer:myboard.deploy_live   -- <host-or-ip> [--user root]

    bazel run //consumer:myboard.keys          -- {init|ensure|rotate|path|pub}

Each is an sh_binary whose src is a small launcher (launch.sh) that execs a
nixpkgs-vendored bash on the real script (sbc_deploy.sh) — so the tool runs
under a hermetic bash, not the host's system bash (macOS ships 3.2). Per-project
configuration is baked in via the sh_binary `args`, passed before the operator's
own `-- ...` arguments. The two leading args are the runfiles paths the launcher
resolves.
"""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# Label() captures this .bzl file's own repo, so these resolve to @sbc_deploy /
# its deps no matter which repo/package calls the macro.
_LAUNCHER = Label("//deploy:scripts/launch.sh")
_SCRIPT = Label("//deploy:scripts/sbc_deploy.sh")
_BASH = Label("@nixpkgs_bash//:bash")
_YJ = Label("@nixpkgs_yj//:yj")
_ZSTD = Label("@nixpkgs_zstd//:zstd")
_PV = Label("@nixpkgs_pv//:pv")
_RUNFILES = Label("@bazel_tools//tools/bash/runfiles:runfiles")

def sbc_application(
        name,
        flake,
        hostname = None,
        project = None,
        framework = None,
        wifi_config_file = None,
        visibility = None):
    """Create the three deploy-mode targets (+ keys) for one SBC application.

    Args:
      name: base name; targets are <name>.image_sd / .image_sd_base /
        .deploy_live / .keys.
      flake: workspace-relative path to the directory holding flake.nix (which
        returns `sbc-deploy.lib.mkSbcProject { … }`).
      hostname: nixosConfigurations attr name for live deploy (default: project).
      project: project name for key comment/messages (default: name).
      framework: workspace-relative path to sbc-deploy's own `nix/` flake dir,
        when it lives in the same source tree (in-repo, or vendored in-tree).
        When set, builds inject it via `--override-input sbc-deploy path:…` so
        Bazel is the single source of the framework version — no
        `nix flake update`. Omit for external bazel_dep consumers, who pin the
        framework via their own flake input.
      wifi_config_file: label of a single YAML file listing WiFi networks (ssid /
        psk / priority / hidden) to auto-connect to. Converted to JSON at build
        time and baked into the image. Merges with any inline `sbcDeploy.wifi`.
      visibility: visibility for the generated targets.
    """
    project = project or name
    hostname = hostname or project
    base = ["--project", project, "--flake-subdir", flake]
    if framework:
        base += ["--framework-subdir", framework]

    # Declarative WiFi: convert the YAML to JSON in the Bazel graph so Nix reads
    # it natively (fromJSON). The launcher resolves the JSON's runfiles path and
    # exports it for eval. Empty third lead arg when there's no config file.
    wifi_data = []
    wifi_lead = "-"  # sentinel: no wifi config file
    if wifi_config_file:
        json_out = name + "_wifi.json"
        native.genrule(
            name = name + "_wifi_json",
            srcs = [wifi_config_file],
            outs = [json_out],
            tools = [_YJ],
            cmd = "$(execpath {yj}) -yj < $(execpath {yaml}) > $@".format(
                yj = _YJ,
                yaml = wifi_config_file,
            ),
        )
        wifi_data = [":" + json_out]
        wifi_lead = "$(rlocationpath :{})".format(json_out)

    # The launcher resolves these runfiles paths, then execs bash on the script.
    # rlocationpath is repo-qualified, so it works from any consumer. Order:
    # script, bash, wifi-json (or "-"), zstd, pv.
    lead = [
        "$(rlocationpath {})".format(_SCRIPT),
        "$(rlocationpath {})".format(_BASH),
        wifi_lead,
        "$(rlocationpath {})".format(_ZSTD),
        "$(rlocationpath {})".format(_PV),
    ]
    data = [_SCRIPT, _BASH, _ZSTD, _PV, _RUNFILES] + wifi_data

    def _target(suffix, argv):
        sh_binary(
            name = name + "." + suffix,
            srcs = [_LAUNCHER],
            data = data,
            args = lead + argv,
            visibility = visibility,
        )

    # Mode 1: full system + bundled app.
    _target("image_sd", ["image"] + base + ["--attr", "images.sdImage"])

    # Mode 2: minimal base system (networking config), no app.
    _target("image_sd_base", ["image"] + base + ["--attr", "images.sdImageBase"])

    # Mode 3: switch a running board to the full system (app + system deps).
    _target("deploy_live", ["deploy"] + base + ["--hostname", hostname])

    _target("keys", ["keys"] + base)

def sbc_linux_builder(name = "linux_builder", framework = "nix", visibility = None):
    """A target that starts the sized-up linux-builder VM (macOS aarch64).

    `bazel run //…:linux_builder` — starts the VM (long-running; leave it up in
    its terminal), so building images on macOS needs no manual `nix run`.

    Args:
      name: target name.
      framework: workspace-relative path to sbc-deploy's `nix/` dir; the builder
        flake is its `builder/` subdir. Only meaningful in-repo / vendored.
      visibility: target visibility.
    """
    sh_binary(
        name = name,
        srcs = [_LAUNCHER],
        data = [_SCRIPT, _BASH, _RUNFILES],
        args = [
            "$(rlocationpath {})".format(_SCRIPT),
            "$(rlocationpath {})".format(_BASH),
            "-",  # no wifi config file
            "-",  # no zstd (the builder never flashes)
            "-",  # no pv
            "builder",
            "--framework-subdir",
            framework,
        ],
        visibility = visibility,
    )
