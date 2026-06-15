{ config, pkgs, lib, secretsDir ? ../../secrets, ... }:
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

  age.secrets.adguard-admin = {
    file = "${secretsDir}/adguard-admin.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  systemd.services.adguardhome = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig.ExecStartPre = [
      ("+" + injectAdminUser)
    ];
  };

  services.adguardhome = {
    enable = true;
    host = "10.20.0.1";
    port = 3000;
    mutableSettings = false;

    settings = {
      users = [ ];
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        bootstrap_dns = [ "1.1.1.1" "9.9.9.9" ];
        upstream_dns = [ "tls://1.1.1.1" "https://dns.quad9.net/dns-query" ];
      };
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
        rewrites = [
          { domain = "grafana.syslabs.dev"; answer = "10.20.0.50"; enabled = true; }
          { domain = "home.syslabs.dev"; answer = "10.20.0.50"; enabled = true; }
          { domain = "longhorn.syslabs.dev"; answer = "10.20.0.50"; enabled = true; }
          { domain = "pgadmin.syslabs.dev"; answer = "10.20.0.50"; enabled = true; }
          { domain = "rancher.syslabs.dev"; answer = "10.20.0.50"; enabled = true; }
          { domain = "traefik.syslabs.dev"; answer = "10.20.0.50"; enabled = true; }
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
