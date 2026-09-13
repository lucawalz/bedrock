{
  config,
  inventory,
  secretsDir ? ../../secrets,
  ...
}:
{
  imports = [ ../tailscale/client.nix ];

  age.secrets.tailscale-authkey = {
    file = "${secretsDir}/tailscale-authkey.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  bedrock.tailscaleClient = {
    enable = true;
    hostname = "router";
    authKeyFile = config.age.secrets.tailscale-authkey.path;
    tag = "tag:cluster";
    advertiseSubnet = inventory.subnet;
    acceptRoutes = true;
  };

  systemd.services.tailscaled.restartTriggers = [ config.age.secrets.tailscale-authkey.file ];
}
