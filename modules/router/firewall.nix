{ lib, ... }:
let
  homeSubnet = "192.168.2.0/24";
  serviceVip = "10.20.0.50";
in
{
  networking = {
    nftables.enable = true;

    nat = {
      enable = true;
      externalInterface = "end0";
      internalInterfaces = [
        "vlan20"
        "vlan30"
      ];
    };

    firewall = {
      enable = true;
      filterForward = true;
      allowedUDPPorts = [ 53 ];
      trustedInterfaces = [
        "vlan20"
        "tailscale0"
      ];

      interfaces.vlan20.allowedTCPPorts = [
        22
        53
        3000
      ];

      interfaces.vlan30 = {
        allowedTCPPorts = [ 53 ];
        allowedUDPPorts = [
          53
          67
        ];
      };

      extraForwardRules = lib.mkMerge [
        (lib.mkBefore ''iifname "vlan20" ip daddr ${homeSubnet} drop'')
        (lib.mkBefore ''iifname "vlan30" ip daddr ${homeSubnet} drop'')
        ''iifname "end0" oifname "vlan20" ip daddr ${serviceVip} tcp dport { 80, 443 } accept''
        ''iifname "tailscale0" oifname "vlan20" accept''
        ''iifname "vlan20" oifname "tailscale0" accept''
        ''iifname "vlan30" oifname "end0" accept''
        ''iifname "vlan30" oifname "vlan20" drop''
      ];
    };
  };
}
