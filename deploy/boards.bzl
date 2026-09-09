"""Board definitions for `sbc_application`.

A board definition picks a platform `family` and, for the Raspberry Pi family,
names a `nixos-raspberrypi` board (which selects the right closure components —
kernel, firmware, device tree, bootloader) plus the optional board submodules to
import (e.g. `display-vc4`). It's a first-class Bazel target carrying
`SbcBoardInfo`, fed to the `board = ` attribute of `sbc_application()`:

    load("@sbc_deploy//deploy:boards.bzl", "sbc_board")

    sbc_board(name = "my-pi", nixos_board = "raspberry-pi-4", modules = ["display-vc4"])
    sbc_board(name = "my-box", nixos_board = "generic-x86", family = "x86_64")

    sbc_application(name = "app", board = ":my-pi", flake = "nix", ...)

Predefined boards live at
`@sbc_deploy//deploy/boards:{raspberry-pi-5,-4,-3,-02,amd64-generic}`.

Mechanically, the rule writes a THREE-line file — board name, comma-joined module
names, then the family — that the launcher (`launch.sh`) resolves from runfiles
and exports as `$SBC_BOARD` / `$SBC_BOARD_MODULES` / `$SBC_BOARD_FAMILY`, which
`mkSbcSystem` reads at eval. Two-line files from older definitions still parse
(the missing family reads back as "" ⇒ raspberrypi).
"""

SbcBoardInfo = provider(
    doc = "Describes a target SBC board for `sbc_application`.",
    fields = {
        "board": "nixos-raspberrypi board module name, e.g. \"raspberry-pi-3\".",
        "modules": "Optional nixos-raspberrypi board submodules to import (list of strings), e.g. [\"display-vc4\"].",
        "family": "Platform family selecting the system builder: \"raspberrypi\" (default) or \"x86_64\".",
    },
)

def _sbc_board_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".board")

    # Three lines: nixos board name, comma-joined submodules, family. The launcher
    # reads them as $SBC_BOARD / $SBC_BOARD_MODULES / $SBC_BOARD_FAMILY. A board
    # file with only the first two lines (older definitions) still parses — the
    # empty family reads back as "" and mkSbcSystem defaults it to raspberrypi.
    ctx.actions.write(
        output = out,
        content = ctx.attr.nixos_board + "\n" +
                  ",".join(ctx.attr.modules) + "\n" +
                  ctx.attr.family + "\n",
    )
    return [
        DefaultInfo(files = depset([out])),
        SbcBoardInfo(
            board = ctx.attr.nixos_board,
            modules = ctx.attr.modules,
            family = ctx.attr.family,
        ),
    ]

sbc_board = rule(
    implementation = _sbc_board_impl,
    doc = "Define an SBC board (a platform family + a nixos-raspberrypi board + optional submodules) for the `board` attr of `sbc_application`.",
    provides = [SbcBoardInfo],
    attrs = {
        "nixos_board": attr.string(
            mandatory = True,
            doc = "nixos-raspberrypi board module name, e.g. \"raspberry-pi-3\". Selects the kernel/firmware/device-tree/bootloader. Informational (ignored) when family = \"x86_64\".",
        ),
        "modules": attr.string_list(
            default = [],
            doc = "Optional nixos-raspberrypi board submodules to import (e.g. \"display-vc4\", \"bluetooth\"). Ones the board doesn't provide are skipped. Unused when family = \"x86_64\".",
        ),
        "family": attr.string(
            default = "raspberrypi",
            values = ["raspberrypi", "x86_64"],
            doc = "Platform family: \"raspberrypi\" (default; a nixos-raspberrypi SD-image system) or \"x86_64\" (a stock nixpkgs amd64 system + a bootable install USB). Selects the system builder + which image targets are meaningful.",
        ),
    },
)
