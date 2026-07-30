"""Public Bazel macro for wiring up sbc-deploy targets in a consuming package.

Usage (in a consumer BUILD.bazel):

    load("@sbc_deploy//deploy:defs.bzl", "sbc_deploy")

    sbc_deploy(
        name = "myboard",
        flake = "path/to/nix",   # workspace-relative dir containing flake.nix
        hostname = "myboard",    # nixosConfigurations.<hostname>; default = project
        project = "myboard",     # key comment + messages; default = name
    )

This creates three runnable targets:

    bazel run //consumer:myboard.image_sd    -- [--device /dev/sdX] [--no-write]
    bazel run //consumer:myboard.deploy_live -- <host-or-ip> [--user root]
    bazel run //consumer:myboard.keys        -- {init|ensure|rotate|path|pub}

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
_RUNFILES = Label("@bazel_tools//tools/bash/runfiles:runfiles")

def sbc_deploy(
        name,
        flake,
        hostname = None,
        project = None,
        image_attr = "images.sdImage",
        visibility = None):
    """Create image_sd / deploy_live / keys targets for one SBC config.

    Args:
      name: base name; targets are <name>.image_sd/.deploy_live/.keys.
      flake: workspace-relative path to the directory holding flake.nix.
      hostname: nixosConfigurations attr name for live deploy (default: project).
      project: project name for key comment/messages (default: name).
      image_attr: flake attribute for the SD image (default: images.sdImage).
      visibility: visibility for the generated targets.
    """
    project = project or name
    hostname = hostname or project
    base = ["--project", project, "--flake-subdir", flake]

    # The launcher resolves these two runfiles paths, then execs bash on the
    # script. rlocationpath is repo-qualified, so it works from any consumer.
    lead = [
        "$(rlocationpath {})".format(_SCRIPT),
        "$(rlocationpath {})".format(_BASH),
    ]
    data = [_SCRIPT, _BASH, _RUNFILES]

    def _target(suffix, argv):
        sh_binary(
            name = name + "." + suffix,
            srcs = [_LAUNCHER],
            data = data,
            args = lead + argv,
            visibility = visibility,
        )

    _target("image_sd", ["image"] + base + ["--attr", image_attr])
    _target("deploy_live", ["deploy"] + base + ["--hostname", hostname])
    _target("keys", ["keys"] + base)
