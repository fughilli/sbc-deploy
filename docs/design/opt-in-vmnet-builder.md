# Design: opt-in `vmnet` networking for the macOS builder VM

**Status:** Proposed — design only, not implemented.
**Scope:** `nix/builder/`, `deploy/scripts/sbc_deploy.sh`, docs.
**Default behavior is unchanged:** without opting in, the builder uses today's
QEMU user-mode (SLIRP) networking exactly as it does now.

## 1. Problem

On macOS, image builds are dispatched to the auto-managed QEMU `linux-builder`
VM (`deploy/scripts/sbc_deploy.sh` → `start_managed_builder`, using the sized
`nix/builder/flake.nix`). Nix store-path copies **to/from** that VM top out at
~100 MiB/s regardless of the fact that it is "local."

Root cause is **QEMU user-mode networking (SLIRP)**. The stock
`darwin.linux-builder` (which we `.override` for RAM/disk/cores only) forwards
SSH via `virtualisation.forwardPorts` — a `hostfwd=tcp::31022-:22` on a
`-netdev user` interface (see `nixos/modules/profiles/nix-builder-vm.nix` and the
`networkingOptions` default in `nixos/modules/virtualisation/qemu-vm.nix`). SLIRP
is a single-threaded userspace TCP/IP stack running inside the QEMU process, so
every byte is copied through it and it competes with the vCPUs. ~100 MiB/s is its
normal ceiling; the transfer is not limited by SSH crypto (hardware-accelerated
on Apple Silicon) or disk.

The dominant transfer for an image build is the **built image copied back** to
the host store (build *inputs* mostly come straight from the binary cache because
`--builders-use-substitutes true` is already set). So the copy-back is exactly
what SLIRP throttles.

Apple's **vmnet** framework provides a near-line-rate NIC backend and would remove
this ceiling.

## 2. Goals / non-goals

**Goals**
- Optional near-line-rate builder networking via `vmnet`.
- **Opt-in.** When not enabled, the QEMU networking configuration is byte-for-byte
  what it is today (SLIRP, auto-managed VM, `hostfwd :31022→:22`).
- **The vmnet builder is started separately**, out-of-band, taking the one
  interactive `sudo` prompt there. The deploy itself stays unprivileged and only
  *connects* to an already-running builder.

**Non-goals**
- Changing or removing the default SLIRP path.
- Signing QEMU with the `com.apple.vm.networking` entitlement.
- Packaging `socket_vmnet` for a no-`sudo` root-helper path (see §7, future work).
- `vmnet-bridged` / exposing the builder on the LAN.

## 3. Findings that make this feasible

1. **Clean override point, no guest rebuild.** The QEMU command line is generated
   by `qemu-vm.nix` from `virtualisation.qemu.networkingOptions`. Setting that
   option in a builder module changes only the **darwin-side runner**
   (`config.system.build.vm`), *not* the aarch64 guest `toplevel`. So the guest
   closure stays byte-identical and cache-served — the same property `sizeModule`
   relies on, and it avoids the bootstrap trap called out in `nix/builder/flake.nix`.

2. **Guest already uses DHCP.** The builder guest runs `dhcpcd` on `eth0` with no
   static SLIRP address, so under `vmnet-shared` (which provides its own DHCP) the
   guest simply leases a vmnet address. **No guest-closure change is required.**

3. **The blocker is privilege, and it is well understood.** `vmnet` requires root:
   nixpkgs' QEMU is unsigned (no `com.apple.vm.networking` entitlement), and
   `socket_vmnet` (the helper Lima/Colima use to avoid per-run `sudo`) is **not**
   packaged in the pinned nixpkgs (25.05). Therefore the vmnet builder VM must be
   launched under `sudo`. This design confines that `sudo` to a **separate,
   interactive builder-start step**, keeping it out of the deploy hot path.

## 4. Design

### 4.1 Opt-in signal
- Env `SBC_VMNET=1` (and a matching `--vmnet` flag on the deploy targets).
- Unset ⇒ **identical to today** (SLIRP, `start_managed_builder`, `:31022`).

### 4.2 Separate builder lifecycle (the core of the request)
- A new flake app in `nix/builder/`, e.g. `#linux-builder-vmnet`: the existing
  sized builder plus a `vmnetModule` (below). The user starts it themselves,
  under `sudo`, out-of-band:

  ```sh
  sudo nix run 'github:fughilli/sbc-deploy?dir=nix/builder#linux-builder-vmnet'
  ```

  (Optionally wrapped as a `sbc_application` sub-target, e.g.
  `bazel run //path:NAME.builder -- --vmnet`, which `exec`s the above under
  `sudo`.) The interactive `sudo` prompt happens here, once per session; the VM
  stays running in that shell.

- The deploy (`.image_sd` / `.deploy_live`), when `SBC_VMNET` is set, **skips**
  `start_managed_builder` entirely and connects to the already-running vmnet
  builder. If it can't reach one, it fails fast with:
  `"vmnet mode: start the builder first — sudo nix run …#linux-builder-vmnet"`.

This cleanly separates the one privileged, interactive action (start the VM) from
the unprivileged, scriptable action (build + copy), which is exactly the
"kick off the builder separately" model.

### 4.3 `vmnetModule` (nix/builder)
Runner-only override (guest stays cached); illustrative:

```nix
vmnetModule = { lib, ... }: {
  virtualisation.qemu.networkingOptions = lib.mkForce [
    "-device virtio-net-pci,netdev=vmnet.0,mac=52:54:00:5b:c0:01"
    ("-netdev vmnet-shared,id=vmnet.0"
      + ",start-address=192.168.106.1,end-address=192.168.106.2"
      + ",subnet-mask=255.255.255.0")
  ];
};
```

- Pins a small vmnet subnet so the single guest deterministically leases
  `192.168.106.2` (host/gateway `.1`); a fixed MAC allows lease lookup if needed.
- Drops the SLIRP `hostfwd` (vmnet has no localhost port-forward).
- `mkForce` beats the `forwardPorts`-derived default from `qemu-vm.nix`.

### 4.4 Addressing / connection
With vmnet the deploy connects to the guest's vmnet IP on `:22` (not
`localhost:31022`). The `--builders` spec becomes:

```
ssh-ng://builder@192.168.106.2 aarch64-linux <key> 6 - big-parallel,kvm,benchmark - <hostkey-b64>
```

The builder's **host key is unchanged** (the fixed key baked into the guest); only
the address changes, and the deploy already passes the base64 host key in the
`--builders` spec, so host-key verification still holds. **IP-discovery fallback**
(if the pinned lease proves unreliable across macOS releases): look up the fixed
MAC in `/var/db/dhcpd_leases`, or `arp -an`.

### 4.5 `sbc_deploy.sh` changes (specification, not code)
- Add the `SBC_VMNET` / `--vmnet` gate. When set:
  - `BUILDER_HOST=192.168.106.2`, `BUILDER_PORT=22`.
  - **Skip** `start_managed_builder` (builder is externally, privileged-managed).
  - `wait_for_builder` / readiness probe SSHes to `${BUILDER_HOST}:22`.
  - `BUILDER_ARGS` ssh-ng URI targets `${BUILDER_HOST}` instead of the `:31022`
    hostfwd alias.
  - Add a `.builder --vmnet` helper that `exec`s `sudo nix run …#linux-builder-vmnet`.
- When unset: the code path is **unchanged** (SLIRP, auto-managed, `:31022`,
  `pgrep`/`pkill` on the `hostfwd=tcp::31022-` pattern).

### 4.6 Privilege model
`sudo` is required **only** for the separate builder start (interactive, once per
session). The deploy stays unprivileged and merely SSHes into the running builder.
This avoids `sudo` in the deploy hot path and the fragility of backgrounding QEMU
under `sudo`.

## 5. Verification plan (must run on macOS; cannot be validated on Linux/CI)

1. **Gate check:** `qemu-system-aarch64 -netdev help | grep -i vmnet` — confirm the
   nixpkgs QEMU actually has `vmnet` compiled in (see §6 risk).
2. Start the vmnet builder under `sudo`; confirm the guest leases `192.168.106.2`
   and `ssh -i <key> builder@192.168.106.2` succeeds.
3. **Throughput A/B:** `nix copy` a multi-GB path to the builder over SLIRP vs
   vmnet; expect a multiple-× improvement (target: hundreds of MiB/s → GB/s).
4. Full `SBC_VMNET=1 … image_sd`: confirm faster copy-back and a correct image.
5. Confirm the **default** (`SBC_VMNET` unset) path is byte-identical to today.

## 6. Risks / open questions
- **QEMU vmnet support**: is `vmnet` compiled into the pinned nixpkgs QEMU on
  aarch64-darwin? If not, this needs a QEMU override (out of scope) — verify with
  the gate check in §5.1.
- **`vmnet-shared` pinned-IP semantics** may vary across macOS versions; the lease
  /ARP fallback (§4.4) mitigates.
- **VM lifecycle under `sudo`**: teardown is user-driven (`Ctrl-C` / documented
  `pkill`); the builder disk under `sudo` is root-owned (document its path and
  permissions; keep it out of the deploy's `.sbc-build`).
- **Concurrency**: a fixed vmnet subnet ⇒ one vmnet builder at a time (document).
- **First-run cost**: none beyond the sized builder; the guest is cache-served.

## 7. Alternatives considered
- **`sudo` inline in the deploy** — rejected: puts `sudo` in the hot path and makes
  backgrounding QEMU under `sudo` fragile; contradicts the "start it separately"
  requirement.
- **`socket_vmnet` root helper** (Lima/Colima pattern) — best UX (no per-build
  `sudo` after a one-time root setup), but `socket_vmnet` isn't in the pinned
  nixpkgs, so it would need packaging + daemon lifecycle. Good **future** upgrade
  that could slot in behind the same `SBC_VMNET` opt-in.
- **`vmnet-bridged`** — exposes the builder on the LAN and depends on LAN DHCP;
  wrong trust model for a build VM.
- **Sign QEMU with the vmnet entitlement** — removes the `sudo` need but adds a
  code-signing/maintenance burden to the packaged builder.
- **Keep SLIRP, shrink the payload** (e.g. `sdImage.compressImage = true` so the
  copy-back is ~4–6× smaller) — a real mitigation, not a ceiling fix; orthogonal
  and can coexist.

## 8. Rollout
Additive and opt-in; no migration. Document the `#linux-builder-vmnet` app and the
`SBC_VMNET` flow in the README "Building on Apple Silicon" section alongside the
existing SLIRP instructions.
