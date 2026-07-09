# K3s control plane (server) module
{ config, secretsDir ? ../../secrets, ... }:
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
      "--etcd-s3"
      "--etcd-s3-bucket=basalt-backups"
      "--etcd-s3-region=eu-central-1"
      "--etcd-s3-endpoint=hel1.your-objectstorage.com"
      "--etcd-s3-folder=etcd-snapshots"
      "--etcd-snapshot-schedule-cron=0 */12 * * *"
      "--etcd-snapshot-retention=5"
    ];
    tokenFile = config.age.secrets.k3s-token.path;
    clusterInit = true;
  };

  age.secrets.etcd-s3-credentials = {
    file = "${secretsDir}/etcd-s3-credentials.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  systemd.services.k3s.serviceConfig.EnvironmentFile =
    config.age.secrets.etcd-s3-credentials.path;

  # Firewall ports for K3s control plane
  networking.firewall.allowedTCPPorts = [
    6443
    10250
    9100
    7946
  ];
  networking.firewall.allowedUDPPorts = [
    8472
    7946
  ];
}
