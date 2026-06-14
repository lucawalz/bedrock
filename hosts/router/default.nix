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
    ../../modules/router/wireguard.nix
    ../../modules/router/monitoring.nix
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  networking.hostName = "router";

  boot.kernelParams = [ "console=ttyS0,115200" "console=tty1" ];

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHoKFFTFmJR1CSAq55TwXHbUPTxSK847qZL0W6r/ZUV9 luca@macbook"
  ];

  system.stateVersion = "25.05";
}
