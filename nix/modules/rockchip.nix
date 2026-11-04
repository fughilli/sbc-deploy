# Rockchip (RK3588 / RK3588S) board support: the counterpart of a
# nixos-raspberrypi board module for the "rockchip" family.
#
# Everything here is mainline: a stock nixpkgs kernel (the board's device tree is
# in-tree), mainline U-Boot built with Rockchip's rkbin DDR blob (TPL) and the
# RK3588 TF-A, and extlinux (generic-extlinux-compatible) for the boot menu. No
# vendor BSP kernel, so the closure is the same one `deploy_live` can switch live.
#
# SD image layout (what the RK3588 boot ROM expects):
#   sector 64  (32 KiB)   u-boot-rockchip.bin  idbloader (TPL+SPL) then u-boot.itb
#   16 MiB                FIRMWARE partition (unused here; keeps clear of U-Boot)
#   then                  ext4 root with /boot/extlinux and the kernel/initrd/dtb
# U-Boot finds the root partition and boots it from extlinux; the boot ROM tries
# SD before eMMC, so an SD-card image boots even over an old eMMC install.
#
# Selected by the board name in `sbcRockchip.board` (set by mkSbcSystem from the
# board definition). Add a board by extending `boards` below with its U-Boot
# defconfig, in-tree DTB and debug console.
{ config, lib, pkgs, modulesPath, ... }:
let
  cfg = config.sbcRockchip;

  boards = {
    # FriendlyElec NanoPi R6S: RK3588S, 8 GB LPDDR4X, 32 GB eMMC, microSD,
    # 2x 2.5GbE (RTL8125) + 1x GbE, 2x USB 3.0, debug UART on uart2.
    nanopi-r6s = {
      defconfig = "nanopi-r6s-rk3588s_defconfig";
      dtb = "rockchip/rk3588s-nanopi-r6s.dtb";
      console = "ttyS2,1500000n8";
    };
  };

  board = boards.${cfg.board} or (throw
    "sbc-deploy: unknown rockchip board '${cfg.board}' (known: ${lib.concatStringsSep ", " (lib.attrNames boards)})");

  uboot = pkgs.buildUBoot {
    defconfig = board.defconfig;
    extraMeta.platforms = [ "aarch64-linux" ];
    BL31 = "${pkgs.armTrustedFirmwareRK3588}/bl31.elf";
    ROCKCHIP_TPL = pkgs.rkbin.TPL_RK3588;
    filesToInstall = [ "u-boot-rockchip.bin" ];
  };
in
{
  imports = [ (modulesPath + "/installer/sd-card/sd-image.nix") ];

  options.sbcRockchip.board = lib.mkOption {
    type = lib.types.str;
    default = "nanopi-r6s";
    description = "Rockchip board name (a key of `boards` in rockchip.nix).";
  };

  config = {
    nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

    # rkbin's DDR init blob is redistributable but not free software.
    nixpkgs.config.allowUnfreePredicate = pkg: (lib.getName pkg) == "rkbin";

    # Mainline kernel; RK3588 and these boards' DTBs are in-tree since 6.9.
    boot.kernelPackages = pkgs.linuxPackages;
    boot.kernelParams = [ "console=${board.console}" "console=tty1" ];
    hardware.deviceTree = {
      enable = true;
      name = board.dtb;
    };

    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible.enable = true;
    boot.initrd.availableKernelModules = [
      "dw_mmc_rockchip"      # microSD
      "sdhci_of_dwcmshc"     # eMMC
      "mmc_block"
      "phy_rockchip_naneng_combphy"
      "phy_rockchip_usbdp"
      "usbhid"
    ];

    # No Raspberry Pi wireless firmware to swap in: keep the generic blob (the
    # M.2 slot takes arbitrary Wi-Fi/NVMe cards). See sbc-base.nix.
    sbcDeploy.leanFirmware = lib.mkDefault false;

    sdImage = {
      imageBaseName = "${config.networking.hostName}-${cfg.board}";
      # Keep the FIRMWARE partition clear of U-Boot (idbloader + u-boot.itb run
      # to roughly 9 MiB from sector 64).
      firmwarePartitionOffset = 16;
      firmwareSize = 32;
      populateFirmwareCommands = "";
      populateRootCommands = ''
        mkdir -p ./files/boot
        ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
          -c ${config.system.build.toplevel} -d ./files/boot
      '';
      postBuildCommands = ''
        dd if=${uboot}/u-boot-rockchip.bin of=$img seek=64 conv=notrunc
      '';
    };
  };
}
