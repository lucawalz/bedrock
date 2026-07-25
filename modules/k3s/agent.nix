# K3s worker (agent) module
{ config, ... }:

{
  imports = [ ./common.nix ];

  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://master:6443";
    tokenFile = config.age.secrets.k3s-token.path;
    extraFlags = [
      "--node-label=bedrock.io/storage=true"
    ];
  };
}
