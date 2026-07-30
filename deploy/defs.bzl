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

All three are thin sh_binary wrappers around one generic script; the per-project
configuration is baked in via the sh_binary `args` (passed before the operator's
own `-- ...` arguments when run).
"""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# Label() captures this .bzl file's own repo, so the script resolves to
# @sbc_deploy//deploy:... no matter which repo/package calls the macro.
_SCRIPT = Label("//deploy:scripts/sbc_deploy.sh")

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

    sh_binary(
        name = name + ".image_sd",
        srcs = [_SCRIPT],
        args = ["image"] + base + ["--attr", image_attr],
        visibility = visibility,
    )
    sh_binary(
        name = name + ".deploy_live",
        srcs = [_SCRIPT],
        args = ["deploy"] + base + ["--hostname", hostname],
        visibility = visibility,
    )
    sh_binary(
        name = name + ".keys",
        srcs = [_SCRIPT],
        args = ["keys"] + base,
        visibility = visibility,
    )
