{ lib, inventory, ... }:
let
  homeSubnet = "192.168.2.0/24";
  inherit (inventory) nodes serviceVip;
  nodeAddresses = lib.concatStringsSep ", " (lib.attrValues nodes);
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
        "wlan0"
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

      interfaces = {
        vlan20.allowedTCPPorts = [
          22
          53
          3000
        ];

        vlan30 = {
          allowedTCPPorts = [ 53 ];
          allowedUDPPorts = [
            53
            67
          ];
        };

        wlan0 = {
          allowedTCPPorts = [ 53 ];
          allowedUDPPorts = [
            53
            67
          ];
        };
      };

      extraForwardRules = lib.mkMerge [
        (lib.mkBefore ''iifname "vlan20" ip daddr ${homeSubnet} drop'')
        (lib.mkBefore ''iifname "vlan30" ip daddr ${homeSubnet} drop'')
        (lib.mkBefore ''iifname "wlan0" ip daddr ${homeSubnet} drop'')
        ''iifname "end0" ip saddr ${homeSubnet} oifname "vlan20" ip daddr ${serviceVip} tcp dport { 80, 443 } accept''
        ''iifname "tailscale0" oifname "vlan20" ip daddr { ${nodeAddresses} } tcp dport 22 accept''
        ''iifname "tailscale0" oifname "vlan20" ip daddr ${nodes.master} tcp dport 6443 accept''
        ''iifname "tailscale0" oifname "vlan20" ip daddr ${serviceVip} tcp dport { 80, 443 } accept''
        ''iifname "tailscale0" oifname "vlan20" icmp type echo-request accept''
        ''iifname "tailscale0" oifname "vlan20" drop''
        ''iifname "vlan20" oifname "tailscale0" accept''
        ''iifname "vlan30" oifname "end0" accept''
        ''iifname "vlan30" oifname "vlan20" drop''
        ''iifname "wlan0" oifname "vlan20" ip daddr ${serviceVip} tcp dport { 80, 443 } accept''
        ''iifname "wlan0" oifname "vlan20" drop''
        ''iifname "wlan0" oifname "end0" accept''
      ];
    };
  };
}
