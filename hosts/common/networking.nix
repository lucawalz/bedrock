_:
{
  networking = {
    networkmanager.enable = true;
    hosts."10.20.0.10" = [ "master" ];
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };
}
