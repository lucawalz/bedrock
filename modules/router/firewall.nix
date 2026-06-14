{ lib, ... }:
let
  homeSubnet = "192.168.2.0/24";
in
{
  networking.nftables.enable = true;

  networking.nat = {
    enable = true;
    externalInterface = "end0";
    internalInterfaces = [ "vlan20" "vlan30" ];
  };

  networking.firewall = {
    enable = true;
    filterForward = true;
    allowedTCPPorts = [ 22 53 3000 ];
    allowedUDPPorts = [ 53 ];
    trustedInterfaces = [ "vlan20" "tailscale0" ];

    interfaces.vlan30 = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 67 ];
    };

    extraForwardRules = lib.mkMerge [
      (lib.mkBefore ''iifname "vlan20" ip daddr ${homeSubnet} drop'')
      ''iifname "end0" oifname "vlan20" accept''
      ''iifname "tailscale0" oifname "vlan20" accept''
      ''iifname "vlan20" oifname "tailscale0" accept''
      ''iifname "vlan30" oifname "end0" accept''
      ''iifname "vlan30" oifname "vlan20" drop''
      ''iifname "vlan30" ip daddr ${homeSubnet} drop''
    ];
  };
}
