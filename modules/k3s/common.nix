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

  environment.etc."k3s/flannel-net-conf.json".text =
    ''{"Network":"10.42.0.0/16","Backend":{"Type":"vxlan","MTU":1280}}'';

  services.k3s.extraFlags = [
    "--kubelet-arg=image-gc-high-threshold=70"
    "--kubelet-arg=image-gc-low-threshold=55"
    "--flannel-conf=/etc/k3s/flannel-net-conf.json"
  ];
}
