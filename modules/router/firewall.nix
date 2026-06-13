{ lib, ... }:
let
  homeSubnet = "192.168.2.0/24";
in
{
  networking.nftables.enable = true;

  networking.nat = {
    enable = true;
    externalInterface = "end0";
    internalInterfaces = [ "vlan20" ];
  };

  networking.firewall = {
    enable = true;
    filterForward = true;
    allowedTCPPorts = [ 22 53 3000 ];
    allowedUDPPorts = [ 53 51820 ];
    trustedInterfaces = [ "vlan20" "wg0" ];

    extraForwardRules = lib.mkMerge [
      (lib.mkBefore ''iifname "vlan20" ip daddr ${homeSubnet} drop'')
      ''iifname "end0" oifname "vlan20" accept''
      ''iifname "wg0" oifname "vlan20" accept''
      ''iifname "vlan20" oifname "wg0" accept''
    ];
  };
}
