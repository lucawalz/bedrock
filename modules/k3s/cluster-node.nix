{ lib, pkgs, ... }:
let
  k3sConfigPath = "/etc/rancher/k3s/config.yaml";
  metadataBase = "http://169.254.169.254/hetzner/v1/metadata";
  configWaitSeconds = 540;
  tailscaleAuthKeyPath = "/etc/tailscale/authkey";
  tailscaleIface = "tailscale0";
  tailscaleWaitSeconds = 540;
in
{
  imports = [ ./hetzner-scaffolding.nix ];

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
      name = "iqn.2016-04.com.open-iscsi:bedrock-cluster-node";
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
      package = pkgs.k3s_1_35;
    };
  };

  systemd = {
    tmpfiles.rules = [
      "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
    ];

    services = {
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
          TimeoutStartSec = 120;
        };
        script = ''
          NAME=""
          i=0
          while [ $i -lt 30 ]; do
            NAME=$(${pkgs.curl}/bin/curl -fsS --max-time 5 ${metadataBase}/hostname 2>/dev/null || true)
            [ -n "$NAME" ] && break
            i=$((i+1)); sleep 2
          done
          [ -n "$NAME" ] && ${pkgs.systemd}/bin/hostnamectl set-hostname "$NAME" || true
        '';
      };

      tailscaled-autoconnect = {
        after = [
          "tailscaled.service"
          "hetzner-set-hostname.service"
        ];
        wants = [ "tailscaled.service" ];
        serviceConfig.TimeoutStartSec = lib.mkForce 600;
        preStart = ''
          DEADLINE=$(( $(date +%s) + ${toString tailscaleWaitSeconds} ))
          while [ ! -s ${tailscaleAuthKeyPath} ]; do
            if [ "$(date +%s)" -ge "$DEADLINE" ]; then
              echo "${tailscaleAuthKeyPath} not present within ${toString tailscaleWaitSeconds}s" >&2
              exit 1
            fi
            sleep 2
          done
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
          "network-online.target"
          "cloud-final.service"
          "k3s-cluster-config-augment.service"
        ];
        wants = [
          "network-online.target"
          "k3s-cluster-config-augment.service"
        ];
      };
    };
  };

  system.stateVersion = "25.05";
}
