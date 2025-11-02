# K3s control plane (server/master) role

{ config, pkgs, meta, ... }:

{
  age.secrets.k3s-token = {
    file = ../../secrets/k3s-token.age;
    mode = "0400";
    owner = "root";
    group = "root";
  };

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--write-kubeconfig-mode=0644"
      "--disable=servicelb"
      "--disable=traefik"  # Using Flux-managed Traefik
      "--disable=local-storage"
    ];
    tokenFile = config.age.secrets.k3s-token.path;
    clusterInit = true;
  };

  # Open firewall for K3s API server and agent connections
  networking.firewall.allowedTCPPorts = [ 6443 10250 ];
  networking.firewall.allowedUDPPorts = [ 8472 ]; # Flannel VXLAN
}

