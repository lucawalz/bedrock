# K3s control plane (server) module
{
  config,
  inventory,
  ...
}:
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
      "--disable=coredns"
      "--disable=metrics-server"
      "--tls-san=${inventory.nodes.master}"
      "--tls-san=${inventory.nodes.master.tailscale.address}"
      "--tls-san=${inventory.nodes.master.tailscale.magicDnsName}"
      "--node-ip=${inventory.nodes.master}"
      "--secrets-encryption"
      "--node-label=bedrock.io/storage=true"
      "--etcd-expose-metrics" # binds 2381 beyond loopback so Prometheus can reach it
      "--kubelet-arg=kube-reserved=cpu=800m,memory=4Gi"
      "--kubelet-arg=system-reserved=cpu=200m,memory=512Mi"
      "--etcd-snapshot-schedule-cron=\"0 */12 * * *\""
      "--etcd-snapshot-retention=5"
    ];
    tokenFile = config.age.secrets.k3s-token.path;
    clusterInit = true;
  };

  networking.firewall.allowedTCPPorts = [
    6443
    2381
  ];
}
