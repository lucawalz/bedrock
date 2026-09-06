{
  pkgs,
  lib,
  config,
  inventory,
  ...
}:
let
  cfg = config.services.deadman;

  stateDir = "/run/deadman";
  stampFile = "${stateDir}/last-contact";

  alertmanagerWatchdogRepeatIntervalSeconds = 5 * 60;
  missedBeatsTolerated = 4;
  # the threshold must stay above alertmanager's watchdog repeat interval, or a healthy estate reports stale
  thresholdSeconds = alertmanagerWatchdogRepeatIntervalSeconds * missedBeatsTolerated;

  checkIntervalSeconds = 5 * 60;

  hardening = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    RestrictAddressFamilies = [ "AF_UNIX" ];
    ReadWritePaths = [ stateDir ];
  };

  receive = pkgs.writeShellScript "deadman-receive" ''
    set -u
    ${pkgs.coreutils}/bin/timeout 1 ${pkgs.coreutils}/bin/cat >/dev/null || true
    ${pkgs.coreutils}/bin/date +%s > ${stampFile}.new
    ${pkgs.coreutils}/bin/mv -f ${stampFile}.new ${stampFile}
    printf 'HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n'
  '';

  check = pkgs.writeShellScript "deadman-check" ''
    set -u
    now=$(${pkgs.coreutils}/bin/date +%s)
    last=$(${pkgs.coreutils}/bin/cat ${stampFile} 2>/dev/null || echo 0)
    age=$(( now - last ))
    if [ "$age" -ge ${toString thresholdSeconds} ]; then
      status=stale
      echo "deadman stale: last contact ''${age}s ago, threshold ${toString thresholdSeconds}s" >&2
    else
      status=ok
    fi
    echo "$status" > ${cfg.statusFile}.new
    ${pkgs.coreutils}/bin/chmod 0644 ${cfg.statusFile}.new
    ${pkgs.coreutils}/bin/mv -f ${cfg.statusFile}.new ${cfg.statusFile}
  '';
in
{
  options.services.deadman = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 9095;
      description = "TCP port on vlan20 that receives the alertmanager Watchdog ping.";
    };

    statusFile = lib.mkOption {
      type = lib.types.str;
      default = "${stateDir}/status";
      description = "World-readable file reporting the deadman's last staleness check.";
    };
  };

  config = {
    systemd = {
      tmpfiles.rules = [
        "d ${stateDir} 0755 root root -"
      ];

      sockets.deadman = {
        description = "Alertmanager deadman receiver socket";
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          ListenStream = "${inventory.gateway}:${toString cfg.port}";
          Accept = true;
        };
      };

      services = {
        "deadman@" = {
          description = "Record one alertmanager deadman contact";
          serviceConfig = hardening // {
            Type = "oneshot";
            StandardInput = "socket";
            StandardOutput = "socket";
            ExecStart = receive;
          };
        };

        deadman-check = {
          description = "Check the alertmanager deadman for staleness";
          serviceConfig = hardening // {
            Type = "oneshot";
            ExecStart = check;
          };
        };
      };

      timers.deadman-check = {
        description = "Periodically check the alertmanager deadman for staleness";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnStartupSec = "30s";
          OnUnitActiveSec = "${toString checkIntervalSeconds}s";
          AccuracySec = "5s";
        };
      };
    };
  };
}
