{ ... }:
{
  networking.networkmanager.enable = true;

  networking.hosts."192.168.2.191" = [ "master" ];

  # Firewall: base rules (K3s modules will add their own ports)
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];  # SSH
  };
}
