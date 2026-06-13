{ ... }:
{
  networking.networkmanager.enable = true;

  networking.hosts."10.20.0.10" = [ "master" ];

  # Firewall: base rules (K3s modules will add their own ports)
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];  # SSH
  };
}
