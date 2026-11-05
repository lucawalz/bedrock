{
  config,
  meta,
  inventory,
  secretsDir,
  ...
}:
let
  self = inventory.nodes.${meta.hostname};
  isBootstrap = meta.hostname == inventory.bootstrapControlPlane;
  bootstrap = inventory.nodes.${inventory.bootstrapControlPlane};
in
{
  imports = [ ./common.nix ];

  services.k3s = {
    enable = true;
    extraFlags = [
      "--disable=servicelb" # Using Flux-managed Traefik instead
      "--disable=traefik" # Using Flux-managed Traefik instead
      "--disable=local-storage" # Using Longhorn instead
      "--disable=coredns"
      "--disable=metrics-server"
      "--tls-san=${meta.hostname}"
      "--tls-san=${self.address}"
      "--tls-san=${self.tailscale.address}"
      "--tls-san=${self.tailscale.magicDnsName}"
      "--node-ip=${self.address}"
      "--secrets-encryption"
      "--etcd-expose-metrics" # binds 2381 beyond loopback so Prometheus can reach it
      "--kubelet-arg=kube-reserved=cpu=800m,memory=4Gi"
      "--kubelet-arg=system-reserved=cpu=200m,memory=512Mi"
      "--etcd-s3"
      "--etcd-s3-bucket=bedrock-etcd"
      "--etcd-s3-endpoint=52590e0180355fd2943c3cc27f10d4a3.r2.cloudflarestorage.com"
      "--etcd-s3-region=auto"
      "--etcd-s3-folder=etcd-snapshots"
      "--etcd-snapshot-schedule-cron=\"0 */12 * * *\""
      "--etcd-snapshot-retention=5"
    ];
    tokenFile = config.age.secrets.k3s-token.path;
    environmentFile = config.age.secrets.etcd-s3-credentials.path;
    clusterInit = isBootstrap;
    serverAddr = if isBootstrap then "" else "https://${bootstrap.address}:6443";
  };

  age.secrets.etcd-s3-credentials = {
    file = "${secretsDir}/etcd-s3-credentials.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  networking.firewall.allowedTCPPorts = [
    6443
    2381
  ];
}
