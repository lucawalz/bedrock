# K3s control plane (server) module
{ config, ... }:
{
  imports = [ ./common.nix ];

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--write-kubeconfig-mode=0600"
      "--disable=servicelb" # Using Flux-managed Traefik instead
      "--disable=traefik" # Using Flux-managed Traefik instead
      "--disable=local-storage" # Using Longhorn instead
      "--tls-san=10.20.0.10"
      "--node-ip=10.20.0.10"
      "--secrets-encryption"
      "--node-label=bedrock.io/storage=true"
    ];
    tokenFile = config.age.secrets.k3s-token.path;
    clusterInit = true;
  };

  # Firewall ports for K3s control plane
  networking.firewall.allowedTCPPorts = [
    6443
    10250
    9100
  ];
  networking.firewall.allowedUDPPorts = [ 8472 ]; # Flannel VXLAN
}
