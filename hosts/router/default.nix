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
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  networking.hostName = "router";

  boot.kernelParams = [
    "console=ttyS0,115200"
    "console=tty1"
  ];

  services.openssh.settings.PermitRootLogin = "prohibit-password";
  services.openssh.openFirewall = false;

  system.stateVersion = "25.05";
}
