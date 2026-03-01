{ ... }:
{
  networking.networkmanager.enable = true;

  # Firewall: base rules (K3s modules will add their own ports)
  networking.firewall = {
    enable = true;    # Was previously false!
    allowedTCPPorts = [ 22 ];  # SSH
  };
}
