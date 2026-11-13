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
  auditPolicyEtcPath = "rancher/k3s/audit-policy.yaml";
  auditLogDir = "/var/log/kubernetes";
  auditLogMaxAgeDays = 30;
  auditLogMaxBackups = 10;
  auditLogMaxSizeMegabytes = 100;
  oidcIssuerUrl = "https://id.syslabs.dev";
  oidcClientId = "kubernetes";
  oidcIdentityPrefix = "oidc:";
  auditPolicy = {
    apiVersion = "audit.k8s.io/v1";
    kind = "Policy";
    omitStages = [ "RequestReceived" ];
    rules = [
      {
        level = "None";
        resources = [
          {
            group = "coordination.k8s.io";
            resources = [ "leases" ];
          }
          {
            group = "";
            resources = [ "events" ];
          }
          {
            group = "events.k8s.io";
            resources = [ "events" ];
          }
          {
            group = "authorization.k8s.io";
            resources = [
              "selfsubjectaccessreviews"
              "subjectaccessreviews"
            ];
          }
        ];
      }
      {
        level = "Metadata";
        resources = [
          {
            group = "";
            resources = [
              "secrets"
              "pods/exec"
              "pods/attach"
              "pods/portforward"
            ];
          }
        ];
      }
      {
        level = "None";
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      { level = "Metadata"; }
    ];
  };
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
      "--secrets-encryption-provider=secretbox"
      "--kubelet-arg=kube-reserved=cpu=800m,memory=4Gi"
      "--kubelet-arg=system-reserved=cpu=200m,memory=512Mi"
      "--etcd-s3"
      "--etcd-s3-bucket=bedrock-etcd"
      "--etcd-s3-endpoint=52590e0180355fd2943c3cc27f10d4a3.r2.cloudflarestorage.com"
      "--etcd-s3-region=auto"
      "--etcd-s3-folder=etcd-snapshots"
      "--etcd-snapshot-schedule-cron=\"0 */12 * * *\""
      "--etcd-snapshot-retention=5"
      "--kube-apiserver-arg=audit-policy-file=/etc/${auditPolicyEtcPath}"
      "--kube-apiserver-arg=audit-log-path=${auditLogDir}/audit.log"
      "--kube-apiserver-arg=audit-log-maxage=${toString auditLogMaxAgeDays}"
      "--kube-apiserver-arg=audit-log-maxbackup=${toString auditLogMaxBackups}"
      "--kube-apiserver-arg=audit-log-maxsize=${toString auditLogMaxSizeMegabytes}"
      "--kube-apiserver-arg=oidc-issuer-url=${oidcIssuerUrl}"
      "--kube-apiserver-arg=oidc-client-id=${oidcClientId}"
      "--kube-apiserver-arg=oidc-username-claim=email"
      "--kube-apiserver-arg=oidc-username-prefix=${oidcIdentityPrefix}"
      "--kube-apiserver-arg=oidc-groups-claim=groups"
      "--kube-apiserver-arg=oidc-groups-prefix=${oidcIdentityPrefix}"
    ];
    tokenFile = config.age.secrets.k3s-token.path;
    agentTokenFile = config.age.secrets.k3s-agent-token.path;
    environmentFile = config.age.secrets.etcd-s3-credentials.path;
    clusterInit = isBootstrap;
    serverAddr = if isBootstrap then "" else "https://${bootstrap.address}:6443";
  };

  age.secrets = {
    k3s-token = {
      file = "${secretsDir}/k3s-token.age";
      mode = "0400";
      owner = "root";
      group = "root";
    };

    etcd-s3-credentials = {
      file = "${secretsDir}/etcd-s3-credentials.age";
      mode = "0400";
      owner = "root";
      group = "root";
    };

    k3s-ca = lib.mkIf isBootstrap {
      file = "${secretsDir}/k3s-ca.age";
      mode = "0400";
      owner = "root";
      group = "root";
    };
  };

  environment.etc.${auditPolicyEtcPath}.text = builtins.toJSON auditPolicy;

  systemd = {
    tmpfiles.rules = [ "d ${auditLogDir} 0700 root root -" ];

    services.k3s.restartTriggers = [ config.environment.etc.${auditPolicyEtcPath}.source ];

    # k3s adopts CA files only if they exist before its first start, and an existing cluster CA must never be replaced.
    services.k3s-ca = lib.mkIf isBootstrap {
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
  };

  networking.firewall.allowedTCPPorts = [ 6443 ];
}
