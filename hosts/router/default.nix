{ modulesPath, ... }:
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
    ../../modules/router/display.nix
    ../../modules/router/desktop.nix
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  networking.hostName = "router";

  services = {
    kioskConsole.enable = true;
    openssh = {
      settings.PermitRootLogin = "prohibit-password";
      openFirewall = false;
    };
  };

  boot.kernelParams = [
    "console=ttyS0,115200"
    "console=tty1"
  ];

  system.stateVersion = "25.05";
}
