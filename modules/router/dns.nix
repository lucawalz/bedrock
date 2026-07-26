{
  config,
  pkgs,
  lib,
  inventory,
  secretsDir ? ../../secrets,
  ...
}:
let
  adminUser = "admin";
  configFile = "/var/lib/AdGuardHome/AdGuardHome.yaml";
  injectAdminUser = pkgs.writeShellScript "adguard-inject-admin" ''
    export ADGUARD_ADMIN_HASH="$(cat ${config.age.secrets.adguard-admin.path})"
    ${lib.getExe pkgs.yq-go} -i \
      '.users = [{"name": "${adminUser}", "password": strenv(ADGUARD_ADMIN_HASH)}]' \
      "${configFile}"
  '';
in
{
  services.resolved.enable = false;

  networking.resolvconf.useLocalResolver = true;

  age.secrets.adguard-admin = {
    file = "${secretsDir}/adguard-admin.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  systemd.services.adguardhome = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    restartTriggers = [ config.age.secrets.adguard-admin.file ];

    serviceConfig.ExecStartPre = [
      ("+" + injectAdminUser)
    ];
  };

  services.adguardhome = {
    enable = true;
    host = inventory.gateway;
    port = 3000;
    mutableSettings = false;

    settings = {
      users = [ ];
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        bootstrap_dns = [
          "1.1.1.1"
          "9.9.9.9"
        ];
        upstream_dns = [
          "tls://1.1.1.1"
          "https://dns.quad9.net/dns-query"
        ];
      };
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
        rewrites = [
          {
            domain = "alertmanager.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "auth.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "chat.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "flux.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "grafana.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "home.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "kiwix.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "litellm.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "longhorn.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "minio.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "n8n.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "ntfy.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "paperless.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "paperless-ai.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "pgadmin.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "prometheus.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "rackpeek.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "rancher.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "registry.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "rss.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "s3.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "traefik.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
          {
            domain = "velero.syslabs.dev";
            answer = inventory.serviceVip;
            enabled = true;
          }
        ];
      };
      filters = [
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
          name = "AdGuard DNS filter";
          id = 1;
        }
      ];
    };
  };
}
