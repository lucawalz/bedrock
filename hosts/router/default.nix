{
  lib,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
    ../common/locale.nix
    ../common/nix-settings.nix
    ../common/users.nix
    ../../modules/router/network.nix
    ../../modules/router/firewall.nix
    ../../modules/router/dhcp.nix
    ../../modules/router/dns.nix
    ../../modules/router/tailscale.nix
    ../../modules/router/monitoring.nix
    ../../modules/router/deadman.nix
    ../../modules/router/display.nix
    ../../modules/router/desktop.nix
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  networking.hostName = "router";

  hardware = {
    # the full linux-firmware set does not fit twice on the SD card during an upgrade
    enableRedistributableFirmware = lib.mkForce false;
    firmware = [ pkgs.raspberrypiWirelessFirmware ];
    wirelessRegulatoryDatabase = true;
  };

  documentation.enable = false;

  nix.gc.options = lib.mkForce "--delete-older-than 7d";

  services = {
    journald.settings.Journal.SystemMaxUse = "50M";
    kioskConsole.enable = true;
    openssh = {
      settings.PermitRootLogin = "prohibit-password";
      openFirewall = false;
    };
  };

  boot = {
    loader.generic-extlinux-compatible.configurationLimit = 2;

    zfs.forceImportRoot = false;

    kernelParams = [
      "console=ttyS0,115200"
      "console=tty1"
    ];
  };

  system.stateVersion = "25.05";
}
