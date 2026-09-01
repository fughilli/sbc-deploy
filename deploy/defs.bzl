"""Public Bazel macro for wiring up an SBC application's deploy targets.

Pairs with `sbc-deploy.lib.mkSbcProject` on the Nix side, which exposes
`images.sdImage` (base + app), `images.sdImageBase` (base only), and
`nixosConfigurations.<hostName>` (full, for live switch).

Usage (in a consumer BUILD.bazel):

    load("@sbc_deploy//deploy:defs.bzl", "sbc_application")

    sbc_application(
        name = "myboard",
        flake = "path/to/nix",   # workspace-relative dir containing flake.nix
        hostname = "myboard",    # the config's baked hostName / nixosConfigurations
                                 # attr; default = project
        project = "myboard",     # key comment + messages; default = name
    )

Two orthogonal axes, so one config serves many boards:
  * The TARGET picks WHAT to build — a full/base image, or a live switch.
  * `--hostname` picks the machine IDENTITY (networking.hostName, and thus the
    tailscale name / AP SSID under a consumer's naming scheme) — the SAME flag in
    every mode. Omit it to get the baked-in `hostname`.

This creates targets for the three deployment modes (+ key management):

    # Mode 1 — full system image (minimal system + your bundled application):
    bazel run //consumer:myboard.image_sd      -- [--device /dev/sdX] [--no-write] [--hostname <name>]
    # Mode 2 — base system image only (networking, no application):
    bazel run //consumer:myboard.image_sd_base -- [--device /dev/sdX] [--no-write] [--hostname <name>]
    # Mode 3 — push the application (+ its system deps) to a running board:
    bazel run //consumer:myboard.deploy_live   -- <host-or-ip> [--hostname <name>] [--user root]

    # e.g. flash/deploy the same config as several distinct boards:
    #   bazel run //consumer:myboard.image_sd    -- --hostname myboard-2 --device /dev/sdX
    #   bazel run //consumer:myboard.deploy_live -- --hostname myboard-2 192.168.1.20

    # Convenience — ssh in with the deploy key (default <hostname>.local, or
    # <--hostname>.local):
    bazel run //consumer:myboard.ssh           -- [host-or-ip] [--hostname <name>]
    bazel run //consumer:myboard.keys          -- {init|ensure|rotate|path|pub}

Each is an sh_binary whose src is a small launcher (launch.sh) that execs a
nixpkgs-vendored bash on the real script (sbc_deploy.sh) — so the tool runs
under a hermetic bash, not the host's system bash (macOS ships 3.2). Per-project
configuration is baked in via the sh_binary `args`, passed before the operator's
own `-- ...` arguments. The two leading args are the runfiles paths the launcher
resolves.
"""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

def _staged_flake_impl(ctx):
    """Copy the declared flake sources into a TreeArtifact, stripping the
    workspace-relative flake-subdir prefix so flake.nix lands at the tree root.

    This is the HERMETIC source for the nix build: only the files Bazel is told
    about are exposed (no `.bazelisk/`, no editor churn, nothing else in the live
    workspace), and the copy is a real materialised directory — so `nix build
    path:<tree>` reads deterministic content and the same inputs always yield the
    same store path with the same bytes. Pointing nix at the live workspace
    instead let mutable files (a Bazelisk cache rewritten during the deploy) leak
    into the flake narHash, producing colliding store paths with stale content."""
    out = ctx.actions.declare_directory(ctx.label.name + ".flakesrc")
    prefix = ctx.attr.flake_subdir.rstrip("/") + "/"
    pairs = []
    for f in ctx.files.srcs:
        sp = f.short_path
        if not sp.startswith(prefix):
            # A file outside the flake subdir (e.g. an external-repo input) has no
            # sensible place in the tree; skip it rather than clobber the root.
            continue
        pairs.append(f.path + "\t" + sp[len(prefix):])
    manifest = ctx.actions.declare_file(ctx.label.name + ".flakesrc.manifest")
    ctx.actions.write(manifest, "".join([p + "\n" for p in pairs]))
    ctx.actions.run_shell(
        inputs = ctx.files.srcs + [manifest],
        outputs = [out],
        arguments = [out.path, manifest.path],
        command = """
set -euo pipefail
out="$1"; manifest="$2"
tab="$(printf '\\t')"
while IFS="$tab" read -r src dest; do
  [ -n "${dest:-}" ] || continue
  mkdir -p "$out/$(dirname "$dest")"
  cp -f "$src" "$out/$dest"
done < "$manifest"
""",
        mnemonic = "StageFlakeSrc",
        progress_message = "Staging hermetic flake source %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

_staged_flake = rule(
    implementation = _staged_flake_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Every file the flake build reads (flake.nix/.lock, the nix/ " +
                  "modules, the Go module). Declared explicitly so only intended " +
                  "sources are exposed — the whole point of the hermetic staging.",
        ),
        "flake_subdir": attr.string(
            mandatory = True,
            doc = "Workspace-relative dir holding flake.nix; stripped from each " +
                  "src's path so the staged tree is rooted at the flake.",
        ),
    },
    doc = "Materialise the flake sources into a hermetic TreeArtifact for nix.",
)

# Label() captures this .bzl file's own repo, so these resolve to @sbc_deploy /
# its deps no matter which repo/package calls the macro.
_LAUNCHER = Label("//deploy:scripts/launch.sh")
_SCRIPT = Label("//deploy:scripts/sbc_deploy.sh")
_BASH = Label("@nixpkgs_bash//:bash")
_YJ = Label("@nixpkgs_yj//:yj")
_ZSTD = Label("@nixpkgs_zstd//:zstd")
_PV = Label("@nixpkgs_pv//:pv")
_RUNFILES = Label("@bazel_tools//tools/bash/runfiles:runfiles")

# The self-contained darwin linux-builder VM flake, shipped in each deploy
# target's runfiles so the auto-managed builder (macOS) can be realised from the
# Bazel-pinned framework — no in-tree/vendored copy and no `--framework-subdir`,
# so it works for external bazel_dep consumers. See nix/builder and
# start_managed_builder in sbc_deploy.sh.
_BUILDER = Label("//nix/builder:flake.nix")
_BUILDER_SRCS = Label("//nix/builder:srcs")

# Default board definition (see //deploy/boards and //deploy:boards.bzl).
_DEFAULT_BOARD = Label("//deploy/boards:raspberry-pi-5")

def _shquote(s):
    """Single-quote a string so it survives Bazel's Bourne-shell tokenization of a
    `*_binary.args` element as ONE argument. Without this, a value with spaces or
    shell metacharacters — e.g. a `detect_caps_cmd` like
    `lsusb | grep -q 0925:3881 && echo …` — is split into several args when the
    target runs, and stray tokens (`-q`) get misread as flags. The launcher
    forwards "$@" verbatim, so a single quoted token reaches sbc_deploy.sh intact.
    Embedded single quotes are escaped with the standard `'\\''` idiom."""
    return "'" + s.replace("'", "'\\''") + "'"

def sbc_application(
        name,
        flake,
        board = None,
        lean = False,
        hostname = None,
        project = None,
        framework = None,
        wifi_config_file = None,
        build_data = None,
        flake_srcs = None,
        detect_caps_cmd = None,
        visibility = None):
    """Create the three deploy-mode targets (+ keys) for one SBC application.

    Args:
      name: base name; targets are <name>.image_sd / .image_sd_base /
        .deploy_live / .keys.
      flake: workspace-relative path to the directory holding flake.nix (which
        returns `sbc-deploy.lib.mkSbcProject { … }`).
      board: label of a board definition (an `sbc_board` target carrying
        `SbcBoardInfo`) naming the nixos-raspberrypi board + optional submodules.
        Default `//deploy/boards:raspberry-pi-5`; predefined targets live in
        `@sbc_deploy//deploy/boards`. Flows to `mkSbcSystem` via `$SBC_BOARD` /
        `$SBC_BOARD_MODULES`, so the consumer's flake needn't hardcode a board.
      lean: super-lean base image — drop the RPi sd-image rescue toolkit
        (vim/testdisk/ddrescue/…), documentation, and NixOS's default extra
        packages. Right for a headless appliance; leaves coreutils/systemd/your
        shell. Flows to `mkSbcSystem` via `$SBC_LEAN`. Default False.
      hostname: the config's baked-in hostName — the nixosConfigurations attr that
        deploy_live/ssh build (matches mkSbcProject's hostName), and the default
        networking.hostName when no per-deploy --hostname override is given
        (default: project). This is the config's name, NOT a per-board identity;
        set the latter with the operator-facing --hostname flag in any mode.
      project: project name for key comment/messages (default: name).
      framework: workspace-relative path to sbc-deploy's own `nix/` flake dir,
        when it lives in the same source tree (in-repo, or vendored in-tree).
        When set, builds inject it via `--override-input sbc-deploy path:…` so
        Bazel is the single source of the framework version — no
        `nix flake update`. Omit for external bazel_dep consumers, who pin the
        framework via their own flake input; they still get the auto-managed
        macOS builder, since the builder flake (`//nix/builder`) is shipped in
        every generated target's runfiles (see start_managed_builder).
      wifi_config_file: label of a single YAML file listing WiFi networks (ssid /
        psk / priority / hidden) to auto-connect to. Converted to JSON at build
        time and baked into the image. Merges with any inline `sbcDeploy.wifi`.
      build_data: list of labels (files/filegroups) to expose to the flake build
        as a generic data dependency. Each file is added to the deploy target's
        runfiles; the launcher resolves their absolute paths and exports a
        `SBC_BUILD_DATA` manifest, which mkSbcProject parses (under `--impure`)
        into `sbcBuildData` — an attrset keyed by BASENAME, passed to every
        appModule via specialArgs. A module reads e.g.
        `{ sbcBuildData, ... }: { … = sbcBuildData."my_file.bin"; }`. This keeps
        Bazel the single source of build artifacts (no vendoring into the flake
        tree). Basenames must be unique across the list.
      flake_srcs: list of labels (files/filegroups) enumerating EVERY file the
        flake build reads — flake.nix/.lock, the nix/ modules, the whole Go
        module. When set, Bazel stages exactly these into a hermetic TreeArtifact
        (rooted at the flake, `flake`-prefix stripped) and the deploy points `nix
        build path:` at THAT tree instead of the live workspace. This is what
        makes a redeploy deterministic: nothing outside the declared set is
        exposed, so a Bazelisk cache or editor scratch file mutated in the
        workspace during the deploy can't leak into the flake narHash and pin a
        stale, colliding store path. Omit to keep the legacy behaviour (nix reads
        `$BUILD_WORKSPACE_DIRECTORY/<flake>` directly — simpler, non-hermetic).
      detect_caps_cmd: optional shell command run ON the board by the `.update`
        target to report the capabilities the hardware physically has, as SBC_*
        KEY=VALUE lines (e.g. `lsusb | grep -q 0925:3881 && echo SBC_ANALYZER=1`).
        `.update` warns when this disagrees with the board's committed profile.
      visibility: visibility for the generated targets.
    """
    project = project or name
    hostname = hostname or project
    board = board or _DEFAULT_BOARD
    base = ["--project", project, "--flake-subdir", flake]
    if framework:
        base += ["--framework-subdir", framework]
    if lean:
        base += ["--lean"]

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

    # Generic build_data: arbitrary Bazel-built files exposed to the flake. Their
    # runfiles paths ride the lead args (a count, then N paths) so the launcher
    # can resolve + export them as SBC_BUILD_DATA without relying on env
    # forwarding (bazel run only forwards its own client env to the deploy).
    build_data = build_data or []
    build_data_leads = ["$(rlocationpath {})".format(f) for f in build_data]

    # Hermetic flake source: stage the declared srcs into a TreeArtifact and point
    # the nix build at THAT (via $SBC_FLAKE_DIR), never the mutable workspace. "-"
    # sentinel keeps the legacy workspace-path behaviour when flake_srcs is unset.
    staged_flake_lead = "-"
    staged_data = []
    if flake_srcs:
        _staged_flake(
            name = name + "_flakesrc",
            srcs = flake_srcs,
            flake_subdir = flake,
        )
        staged_data = [":" + name + "_flakesrc"]
        staged_flake_lead = "$(rlocationpath :{}_flakesrc)".format(name)

    # The launcher resolves these runfiles paths, then execs bash on the script.
    # rlocationpath is repo-qualified, so it works from any consumer. Order:
    # script, bash, wifi-json (or "-"), zstd, pv, board-file, builder-flake. The
    # board file (two lines: board name, then comma-joined modules) is read by the
    # launcher and exported as $SBC_BOARD / $SBC_BOARD_MODULES for Nix eval; the
    # builder flake is resolved to $SBC_BUILDER_FLAKE so the auto-managed macOS
    # builder can be realised from the pinned framework (see sbc_deploy.sh).
    lead = [
        "$(rlocationpath {})".format(_SCRIPT),
        "$(rlocationpath {})".format(_BASH),
        wifi_lead,
        "$(rlocationpath {})".format(_ZSTD),
        "$(rlocationpath {})".format(_PV),
        "$(rlocationpath {})".format(board),
        "$(rlocationpath {})".format(_BUILDER),
        staged_flake_lead,
        str(len(build_data)),
    ] + build_data_leads

    # _BUILDER (flake.nix) must be listed directly so its $(rlocationpath) in
    # `lead` has a declared prerequisite; _BUILDER_SRCS carries flake.lock into
    # runfiles beside it so the realised path: flake evaluates purely.
    data = [_SCRIPT, _BASH, _ZSTD, _PV, _RUNFILES, board, _BUILDER, _BUILDER_SRCS] + wifi_data + build_data + staged_data

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
    # The target bakes WHICH config to build (--nixos-attr, the mode axis); the
    # operator's --hostname stays free to set the machine identity, consistently
    # with the image modes.
    _target("deploy_live", ["deploy"] + base + ["--nixos-attr", hostname])

    # Mode 3b: the "just make this board current" deploy. Detects the board from
    # the hardware (right kernel closure, structurally), reads the committed
    # capability profile off the board, and reuses the board's identity — no
    # per-board flags, no way to select a mismatched closure. detect_caps_cmd, if
    # given, is the hybrid detect-warn probe (see the macro docstring).
    update_argv = ["update"] + base + ["--nixos-attr", hostname]
    if detect_caps_cmd:
        # Bazel Bourne-tokenizes `args`, so quote the probe (spaces + `| && ||`)
        # to keep it a single argument (else `-q` etc. leak as deploy flags).
        update_argv += ["--detect-cmd", _shquote(detect_caps_cmd)]
    _target("update", update_argv)

    # Convenience: ssh to the board with the deploy key (default <hostname>.local,
    # or <--hostname>.local when the operator overrides the identity).
    _target("ssh", ["ssh"] + base + ["--nixos-attr", hostname])

    _target("keys", ["keys"] + base)

def _tool_target(name, subcommand, framework, visibility):
    """A long-running `nix run` helper (builder VM / harmonia cache) from the
    in-tree framework. No wifi/zstd/pv/deploy tooling, hence the "-" sentinels."""
    sh_binary(
        name = name,
        srcs = [_LAUNCHER],
        data = [_SCRIPT, _BASH, _RUNFILES],
        args = [
            "$(rlocationpath {})".format(_SCRIPT),
            "$(rlocationpath {})".format(_BASH),
            "-",  # no wifi config file
            "-",  # no zstd
            "-",  # no pv
            "-",  # no board definition
            "-",  # no builder flake (this target uses --framework-subdir)
            "-",  # no staged flake source (uses --framework-subdir)
            "0",  # no build_data
            subcommand,
            "--framework-subdir",
            framework,
        ],
        visibility = visibility,
    )

def sbc_linux_builder(name = "linux_builder", framework = "nix", visibility = None):
    """`bazel run //…:linux_builder` — start the sized-up aarch64-linux builder
    VM (macOS), long-running, so building on macOS needs no manual `nix run`.

    Args:
      name: target name.
      framework: workspace-relative path to sbc-deploy's `nix/` dir (its
        `builder/` subdir holds the flake). Only meaningful in-repo / vendored.
      visibility: target visibility.
    """
    _tool_target(name, "builder", framework, visibility)

def sbc_cache(name = "cache", framework = "nix", visibility = None):
    """`bazel run //…:cache` — start the harmonia binary cache serving the local
    nix store, long-running. Its store (and signing key) persist across restarts,
    so cached build artifacts (e.g. the RPi kernel) survive builder restarts.

    Args:
      name: target name.
      framework: workspace-relative path to sbc-deploy's `nix/` dir (its
        `cache/` subdir holds the flake). Only meaningful in-repo / vendored.
      visibility: target visibility.
    """
    _tool_target(name, "cache", framework, visibility)
