{
  config,
  lib,
  pkgs,
  meta,
  inventory,
  secretsDir,
  ...
}:
let
  self = inventory.nodes.${meta.hostname};
  isBootstrap = meta.hostname == inventory.bootstrapControlPlane;
  bootstrap = inventory.nodes.${inventory.bootstrapControlPlane};
  tlsDir = "/var/lib/rancher/k3s/server/tls";
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

  age.secrets.k3s-ca = lib.mkIf isBootstrap {
    file = "${secretsDir}/k3s-ca.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  # k3s adopts CA files only if they exist before its first start, and an existing cluster CA must never be replaced.
  systemd.services.k3s-ca = lib.mkIf isBootstrap {
    description = "Install the stable cluster CA before the first k3s start";
    requiredBy = [ "k3s.service" ];
    before = [ "k3s.service" ];
    unitConfig.ConditionPathExists = "!${tlsDir}/server-ca.crt";
    serviceConfig = {
      Type = "oneshot";
      UMask = "0077";
    };
    path = [ pkgs.gnutar ];
    script = ''
      mkdir -p ${tlsDir}
      tar -xf ${config.age.secrets.k3s-ca.path} -C ${tlsDir} --no-same-owner
    '';
  };

  networking.firewall.allowedTCPPorts = [ 6443 ];
}
