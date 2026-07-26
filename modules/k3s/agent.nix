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
      "--kubelet-arg=kube-reserved=cpu=300m,memory=768Mi"
      "--kubelet-arg=system-reserved=cpu=100m,memory=256Mi"
    ];
  };
}
