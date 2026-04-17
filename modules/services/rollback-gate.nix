{ config, pkgs, meta, ... }:
{
  systemd.services.rollback-gate = {
    description = "NixOS dead-man's switch health gate";
    after = [ "k3s.service" "network-online.target" ];
    requires = [ "k3s.service" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "rollback-gate-check" ''
        set -euo pipefail
        ${pkgs.systemd}/bin/systemctl is-active k3s.service
        status=$(${pkgs.k3s}/bin/kubectl get node "${meta.hostname}" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
        [ "$status" = "True" ]
      '';
      FailureAction = "reboot-force";
      TimeoutStartSec = "120s";
    };
  };

  systemd.timers.rollback-gate = {
    description = "Timer driving the rollback-gate health gate";
    wantedBy = [ "multi-user.target" ];
    timerConfig = {
      OnActiveSec = "18s";
      Unit = "rollback-gate.service";
    };
  };
}
