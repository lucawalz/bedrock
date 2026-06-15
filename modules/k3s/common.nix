# Shared K3s configuration for both server and agent nodes
{ config, pkgs, meta, secretsDir ? ../../secrets, ... }:
{
  age.secrets.k3s-token = {
    file = "${secretsDir}/k3s-token.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  # Critical: Systemd dependency ordering for K3s
  systemd.services.k3s = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
  };

  services.k3s.extraFlags = [
    "--kubelet-arg=image-gc-high-threshold=70"
    "--kubelet-arg=image-gc-low-threshold=55"
  ];
}
