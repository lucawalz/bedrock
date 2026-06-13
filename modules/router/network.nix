{ ... }:
{
  networking.useDHCP = false;
  networking.useNetworkd = true;
  networking.networkmanager.enable = false;

  systemd.network = {
    enable = true;

    netdevs = {
      "10-vlan20" = {
        netdevConfig = {
          Name = "vlan20";
          Kind = "vlan";
        };
        vlanConfig.Id = 20;
      };
      "10-vlan30" = {
        netdevConfig = {
          Name = "vlan30";
          Kind = "vlan";
        };
        vlanConfig.Id = 30;
      };
    };

    networks = {
      "20-end0" = {
        matchConfig.Name = "end0";
        networkConfig.DHCP = "yes";
        vlan = [ "vlan20" "vlan30" ];
      };
      "30-vlan20" = {
        matchConfig.Name = "vlan20";
        address = [ "10.20.0.1/24" ];
        linkConfig.RequiredForOnline = "no";
      };
      "30-vlan30" = {
        matchConfig.Name = "vlan30";
        address = [ "10.30.0.1/24" ];
        linkConfig.RequiredForOnline = "no";
      };
    };
  };
}
