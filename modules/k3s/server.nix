# K3s control plane (server) module
{ config, pkgs, meta, secretsDir ? ../../secrets, ... }:
{
  imports = [ ./common.nix ];

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--write-kubeconfig-mode=0644"
      "--disable=servicelb"        # Using Flux-managed Traefik instead
      "--disable=traefik"          # Using Flux-managed Traefik instead
      "--disable=local-storage"    # Using Longhorn instead
      "--tls-san=100.64.0.3"
      "--tls-san=10.147.17.161"
      "--tls-san=192.168.20.10"
    ];
    tokenFile = config.age.secrets.k3s-token.path;
    clusterInit = true;
  };

  # Firewall ports for K3s control plane
  networking.firewall.allowedTCPPorts = [ 6443 10250 ];
  networking.firewall.allowedUDPPorts = [ 8472 ];  # Flannel VXLAN
}
