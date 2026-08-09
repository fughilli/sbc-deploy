"""Board definitions for `sbc_application`.

A board definition names a `nixos-raspberrypi` board (which selects the right
closure components — kernel, firmware, device tree, bootloader) plus the optional
board submodules to import (e.g. `display-vc4`). It's a first-class Bazel target
carrying `SbcBoardInfo`, fed to the `board = ` attribute of `sbc_application()`:

    load("@sbc_deploy//deploy:boards.bzl", "sbc_board")

    sbc_board(name = "my-pi", nixos_board = "raspberry-pi-4", modules = ["display-vc4"])

    sbc_application(name = "app", board = ":my-pi", flake = "nix", ...)

Predefined boards live at `@sbc_deploy//deploy/boards:{raspberry-pi-5,-4,-3,-02}`.

Mechanically, the rule writes a two-line file — board name, then comma-joined
module names — that the launcher (`launch.sh`) resolves from runfiles and exports
as `$SBC_BOARD` / `$SBC_BOARD_MODULES`, which `mkSbcSystem` reads at eval.
"""

SbcBoardInfo = provider(
    doc = "Describes a target SBC board for `sbc_application`.",
    fields = {
        "board": "nixos-raspberrypi board module name, e.g. \"raspberry-pi-3\".",
        "modules": "Optional nixos-raspberrypi board submodules to import (list of strings), e.g. [\"display-vc4\"].",
    },
)

def _sbc_board_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".board")
    ctx.actions.write(
        output = out,
        content = ctx.attr.nixos_board + "\n" + ",".join(ctx.attr.modules) + "\n",
    )
    return [
        DefaultInfo(files = depset([out])),
        SbcBoardInfo(board = ctx.attr.nixos_board, modules = ctx.attr.modules),
    ]

sbc_board = rule(
    implementation = _sbc_board_impl,
    doc = "Define an SBC board (a nixos-raspberrypi board + optional submodules) for the `board` attr of `sbc_application`.",
    provides = [SbcBoardInfo],
    attrs = {
        "nixos_board": attr.string(
            mandatory = True,
            doc = "nixos-raspberrypi board module name, e.g. \"raspberry-pi-3\". Selects the kernel/firmware/device-tree/bootloader.",
        ),
        "modules": attr.string_list(
            default = [],
            doc = "Optional nixos-raspberrypi board submodules to import (e.g. \"display-vc4\", \"bluetooth\"). Ones the board doesn't provide are skipped.",
        ),
    },
)
