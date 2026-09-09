# hello-amd64

The amd64 (x86_64) counterpart of [`hello-sbc`](../hello-sbc). Same app, same
three deployment modes — but the target is a mini PC (UEFI + systemd-boot) and
the "image" is a **bootable install USB** that installs the system onto the box's
internal disk.

## Build + write the install USB

```sh
# One-time: generate the deploy key pair (public half is baked into the image).
bazel run //examples/hello-amd64:hello.keys -- init

# Build the install USB (no device write — just realise the .iso):
bazel run //examples/hello-amd64:hello.image_installer -- --no-write

# Write it to a USB stick (find the device first: lsblk / diskutil list):
bazel run //examples/hello-amd64:hello.image_installer -- --device /dev/sdX
```

## Install onto the mini PC

1. Plug the USB into the mini PC and boot from it (UEFI boot menu).
2. A small curses installer starts on the console:
   - pick the **target disk**,
   - review the partition layout (512 MiB vfat ESP + ext4 root),
   - confirm the **ERASE**.
3. It installs the fully-baked system offline and reboots into it. Remove the
   USB when prompted.

The installed box comes up on `hello-amd64.local` (mDNS) with the deploy key
trusted, running the demo HTTP server on port 8080.

## Live redeploy

Identical to the Pi path — push a new app/system generation to the running box:

```sh
bazel run //examples/hello-amd64:hello.deploy_live -- hello-amd64.local
```

## Notes

- The whole target closure is embedded in the ISO, so installation needs **no
  network** on the mini PC.
- On an Apple-Silicon Mac the build auto-manages an x86_64-linux builder VM
  (`linux-builder-x86`, a QEMU x86 guest) — no manual setup, the same as the Pi's
  aarch64 builder. First boot of the x86 VM is slow (un-accelerated QEMU), but the
  bulk of the closure substitutes prebuilt from cache. See the top-level README.
- If your mini PC's NVMe/SATA controller isn't covered by the default initrd
  module set, extend `boot.initrd.availableKernelModules` in the framework's
  `nix/modules/x86-target.nix` (or add a small module here).
