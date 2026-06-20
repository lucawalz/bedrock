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

  # Firewall ports for K3s worker
  networking.firewall.allowedTCPPorts = [ 10250 9100 ];
  networking.firewall.allowedUDPPorts = [ 8472 ];  # Flannel VXLAN
}
