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
    };

    networks = {
      "20-end0" = {
        matchConfig.Name = "end0";
        networkConfig.DHCP = "yes";
        vlan = [ "vlan20" ];
      };
      "30-vlan20" = {
        matchConfig.Name = "vlan20";
        address = [ "10.20.0.1/24" ];
        linkConfig.RequiredForOnline = "no";
      };
    };
  };
}
