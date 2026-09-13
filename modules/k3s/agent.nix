{ config, inventory, ... }:

let
  controlPlane = inventory.nodes.${inventory.bootstrapControlPlane};
in
{
  imports = [ ./common.nix ];

  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://${controlPlane.address}:6443";
    tokenFile = config.age.secrets.k3s-token.path;
    extraFlags = [
      "--kubelet-arg=kube-reserved=cpu=300m,memory=768Mi"
      "--kubelet-arg=system-reserved=cpu=100m,memory=256Mi"
    ];
  };
}
