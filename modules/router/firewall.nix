{ ... }:
{
  networking.nftables.enable = true;

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 53 3000 ];
    allowedUDPPorts = [ 53 ];
    trustedInterfaces = [ "vlan10" "vlan20" ];
  };
}
