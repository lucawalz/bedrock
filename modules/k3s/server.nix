# K3s control plane (server) module
{
  config,
  inventory,
  secretsDir ? ../../secrets,
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
      "--tls-san=${inventory.nodes.master}"
      "--node-ip=${inventory.nodes.master}"
      "--secrets-encryption"
      "--node-label=bedrock.io/storage=true"
      "--etcd-expose-metrics" # binds 2381 beyond loopback so Prometheus can reach it
      "--kubelet-arg=kube-reserved=cpu=800m,memory=4Gi"
      "--kubelet-arg=system-reserved=cpu=200m,memory=512Mi"
      "--etcd-s3"
      "--etcd-s3-bucket=basalt-backups"
      "--etcd-s3-region=eu-central-1"
      "--etcd-s3-endpoint=hel1.your-objectstorage.com"
      "--etcd-s3-folder=etcd-snapshots"
      "--etcd-snapshot-schedule-cron=\"0 */12 * * *\""
      "--etcd-snapshot-retention=5"
    ];
    tokenFile = config.age.secrets.k3s-token.path;
    environmentFile = config.age.secrets.etcd-s3-credentials.path;
    clusterInit = true;
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
