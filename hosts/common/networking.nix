{ inventory, ... }:
{
  networking = {
    networkmanager.enable = true;
    hosts.${inventory.nodes.master} = [ "master" ];
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };
}
