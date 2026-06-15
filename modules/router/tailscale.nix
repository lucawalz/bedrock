{ config, secretsDir ? ../../secrets, ... }:
{
  imports = [ ../tailscale/subnet-router.nix ];

  age.secrets.tailscale-authkey = {
    file = "${secretsDir}/tailscale-authkey.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  bedrock.tailscaleSubnetRouter = {
    enable = true;
    hostname = "router";
    authKeyFile = config.age.secrets.tailscale-authkey.path;
    acceptRoutes = true;
  };
}
