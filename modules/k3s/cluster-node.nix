{ lib, pkgs, ... }:
let
  k3sConfigPath = "/etc/rancher/k3s/config.yaml";
  metadataBase = "http://169.254.169.254/hetzner/v1/metadata";
  configWaitSeconds = 540;
  metadataAttempts = 30;
  metadataRetryDelaySeconds = 2;
  metadataTimeoutSeconds = 5;
  metadataDeadlineSeconds = metadataAttempts * (metadataTimeoutSeconds + metadataRetryDelaySeconds);
  tailscaleAuthKeyPath = "/etc/tailscale/authkey";
  tailscaleIface = "tailscale0";
  iscsiInitiatorNamePath = "/etc/iscsi/initiatorname.iscsi";
  iscsiIqnPrefix = "iqn.2016-04.com.open-iscsi";
  placeholderHostname = "localhost";
  cloudInitStageUnits = [
    "cloud-init-local"
    "cloud-init"
    "cloud-config"
    "cloud-final"
  ];
  cloudInitTools = with pkgs; [
    curl
    gnutar
    gzip
    gawk
    coreutils
  ];
in
{
  imports = [
    ./estate.nix
    ./hetzner-scaffolding.nix
  ];

  networking = {
    hostName = "";
    useDHCP = true;
    firewall = {
      checkReversePath = "loose";
      trustedInterfaces = [ tailscaleIface ];
    };
  };

  services = {
    cloud-init = {
      enable = true;
      network.enable = false;
    };

    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
      };
    };

    openiscsi = {
      enable = true;
      name = "${iscsiIqnPrefix}:bedrock-cluster-node";
    };

    tailscale = {
      enable = true;
      useRoutingFeatures = "client";
      authKeyFile = tailscaleAuthKeyPath;
      extraUpFlags = [
        "--accept-routes"
        "--advertise-tags=tag:burst"
      ];
    };

    k3s = {
      enable = true;
      role = "agent";
    };
  };

  systemd = {
    tmpfiles.rules = [
      "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
    ];

    services = lib.mkMerge [
      (lib.genAttrs cloudInitStageUnits (_: {
        path = lib.mkBefore cloudInitTools;
      }))
      {
        hetzner-set-hostname = {
          description = "Set the node hostname from Hetzner metadata";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          before = [
            "tailscaled-autoconnect.service"
            "k3s-cluster-config-augment.service"
            "k3s.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = metadataDeadlineSeconds;
          };
          script = ''
            set -eu
            NAME=""
            i=0
            while [ $i -lt ${toString metadataAttempts} ]; do
              NAME=$(${pkgs.curl}/bin/curl -fsS --max-time ${toString metadataTimeoutSeconds} ${metadataBase}/hostname 2>/dev/null || true)
              if [ -n "$NAME" ]; then
                break
              fi
              i=$((i+1)); sleep ${toString metadataRetryDelaySeconds}
            done
            if [ -z "$NAME" ]; then
              echo "hetzner metadata served no hostname after ${toString metadataAttempts} attempts" >&2
              exit 1
            fi
            ${pkgs.systemd}/bin/hostnamectl set-hostname "$NAME"
          '';
        };

        tailscaled-autoconnect = {
          after = [
            "hetzner-set-hostname.service"
            "cloud-final.service"
          ];
        };

        openiscsi-set-initiator-name = {
          description = "Set the iSCSI initiator name from the discovered hostname";
          after = [ "hetzner-set-hostname.service" ];
          before = [ "iscsid.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -eu
            HOSTNAME=$(${pkgs.coreutils}/bin/cat /proc/sys/kernel/hostname)
            if [ -z "$HOSTNAME" ] || [ "$HOSTNAME" = "${placeholderHostname}" ]; then
              echo "refusing to derive an iSCSI initiator name from hostname '$HOSTNAME'" >&2
              exit 1
            fi
            ${pkgs.coreutils}/bin/rm -f ${iscsiInitiatorNamePath}
            printf 'InitiatorName=%s:%s\n' "${iscsiIqnPrefix}" "$HOSTNAME" > ${iscsiInitiatorNamePath}
          '';
        };

        k3s-cluster-config-augment = {
          description = "Strip cloud-provider flags and add the instance provider-id to the k3s config";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-online.target"
            "cloud-final.service"
            "hetzner-set-hostname.service"
          ];
          wants = [ "network-online.target" ];
          before = [ "k3s.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            Restart = "on-failure";
            RestartSec = 5;
            TimeoutStartSec = 600;
          };
          script = ''
            set -eu
            DEADLINE=$(( $(date +%s) + ${toString configWaitSeconds} ))
            while [ ! -s ${k3sConfigPath} ]; do
              if [ "$(date +%s)" -ge "$DEADLINE" ]; then
                echo "${k3sConfigPath} not written within ${toString configWaitSeconds}s" >&2
                exit 1
              fi
              sleep 2
            done
            ${pkgs.gnused}/bin/sed -i '/- cloud-provider=external/d' ${k3sConfigPath}
            ${pkgs.gawk}/bin/awk '/-arg:[[:space:]]*$/{p=$0;next} {if(p!=""){if($0~/^[[:space:]]*-[[:space:]]/)print p;p=""}print}' ${k3sConfigPath} > ${k3sConfigPath}.tmp && ${pkgs.coreutils}/bin/mv ${k3sConfigPath}.tmp ${k3sConfigPath}
            ID=$(${pkgs.curl}/bin/curl -fsS --max-time 10 ${metadataBase}/instance-id 2>/dev/null || true)
            if [ -n "$ID" ] && ! ${pkgs.gnugrep}/bin/grep -q 'provider-id=' ${k3sConfigPath}; then
              if ${pkgs.gnugrep}/bin/grep -q '^kubelet-arg:' ${k3sConfigPath}; then
                ${pkgs.gnused}/bin/sed -i "/^kubelet-arg:/a - provider-id=hcloud://$ID" ${k3sConfigPath}
              else
                printf 'kubelet-arg:\n- provider-id=hcloud://%s\n' "$ID" >> ${k3sConfigPath}
              fi
            fi
          '';
        };

        k3s = {
          after = [
            "cloud-final.service"
            "k3s-cluster-config-augment.service"
          ];
          wants = [ "k3s-cluster-config-augment.service" ];
        };
      }
    ];
  };

  system.stateVersion = "25.05";
}
