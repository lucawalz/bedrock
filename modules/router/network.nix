{ ... }:
{
  networking.useDHCP = false;
  networking.useNetworkd = true;
  networking.networkmanager.enable = false;

  systemd.network = {
    enable = true;

    netdevs = {
      "10-vlan10" = {
        netdevConfig = {
          Name = "vlan10";
          Kind = "vlan";
        };
        vlanConfig.Id = 10;
      };
      "10-vlan20" = {
        netdevConfig = {
          Name = "vlan20";
          Kind = "vlan";
        };
        vlanConfig.Id = 20;
      };
    };

    networks = {
      "20-end0" = {
        matchConfig.Name = "end0";
        networkConfig.DHCP = "yes";
        vlan = [ "vlan10" "vlan20" ];
      };
      "30-vlan10" = {
        matchConfig.Name = "vlan10";
        address = [ "192.168.10.1/24" ];
      };
      "30-vlan20" = {
        matchConfig.Name = "vlan20";
        address = [ "192.168.20.1/24" ];
      };
    };
  };
}
