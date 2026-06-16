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

  # flannel.1 defaults to 1450 off the 1500 LAN, but burst nodes overlay over tailscale0 (1280); pin 1230 so pod traffic agrees at the tailnet path MTU.
  environment.etc."k3s/flannel-net-conf.json".text =
    ''{"Network":"10.42.0.0/16","Backend":{"Type":"vxlan","MTU":1230}}'';

  services.k3s.extraFlags = [
    "--kubelet-arg=image-gc-high-threshold=70"
    "--kubelet-arg=image-gc-low-threshold=55"
    "--flannel-conf=/etc/k3s/flannel-net-conf.json"
  ];
}
