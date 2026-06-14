{ config, secretsDir ? ../../secrets, ... }:
let
  trustedSubnet = "10.20.0.0/24";
in
{
  age.secrets.tailscale-authkey = {
    file = "${secretsDir}/tailscale-authkey.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
    authKeyFile = config.age.secrets.tailscale-authkey.path;
    extraUpFlags = [
      "--advertise-routes=${trustedSubnet}"
      "--accept-routes"
      # the router runs AdGuard as the LAN resolver, so tailscale must not take over DNS
      "--accept-dns=false"
      "--advertise-tags=tag:cluster"
      "--hostname=router"
    ];
  };
}
