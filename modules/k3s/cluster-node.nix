{ lib, pkgs, ... }:
let
  k3sConfigPath = "/etc/rancher/k3s/config.yaml";
  rolePath = "/etc/rancher/k3s/role";
  metadataBase = "http://169.254.169.254/hetzner/v1/metadata";
  configWaitSeconds = 540;
  k3sPackage = pkgs.k3s_1_35;
  roleCaptureScript = pkgs.writeShellScript "k3s-role-capture" ''
    set -eu
    mkdir -p /etc/rancher/k3s
    case "''${INSTALL_K3S_EXEC:-}" in
      *server*) printf 'server' > ${rolePath} ;;
      *agent*)  printf 'agent'  > ${rolePath} ;;
      *)        : ;;
    esac
    exit 0
  '';
  k3sLauncher = pkgs.writeShellScript "k3s-launch" ''
    set -eu
    ROLE="$(${pkgs.coreutils}/bin/cat ${rolePath} 2>/dev/null || true)"
    if [ -z "$ROLE" ]; then
      if ${pkgs.gnugrep}/bin/grep -q '^cluster-init:[[:space:]]*true' ${k3sConfigPath} 2>/dev/null \
         || ! ${pkgs.gnugrep}/bin/grep -q '^server:' ${k3sConfigPath} 2>/dev/null; then
        ROLE=server
      else
        ROLE=agent
      fi
    fi
    exec ${k3sPackage}/bin/k3s "$ROLE"
  '';
in
{
  imports = [ ./hetzner-scaffolding.nix ];

  networking.hostName = "";
  networking.useDHCP = true;
  networking.firewall.allowedTCPPorts = [ 6443 10250 ];
  networking.firewall.allowedUDPPorts = [ 8472 ];
  networking.firewall.checkReversePath = "loose";

  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  services.openiscsi = {
    enable = true;
    name = "iqn.2016-04.com.open-iscsi:bedrock-cluster-node";
  };

  systemd.tmpfiles.rules = [
    "L+ /opt/install.sh - - - - ${roleCaptureScript}"
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];

  systemd.services.hetzner-set-hostname = {
    description = "Set the node hostname from Hetzner metadata";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    before = [ "k3s-cluster-config-augment.service" "k3s.service" ];
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

  systemd.services.k3s-cluster-config-augment = {
    description = "Augment CAPI-written k3s config with private-network node networking";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "cloud-final.service" "hetzner-set-hostname.service" ];
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
      IP=$(${pkgs.iproute2}/bin/ip -o -4 addr show 2>/dev/null \
        | ${pkgs.gawk}/bin/awk '$4 ~ /^10\.0\./ {print $4}' \
        | ${pkgs.coreutils}/bin/cut -d/ -f1 | ${pkgs.coreutils}/bin/head -1)
      IFACE=$(${pkgs.iproute2}/bin/ip -o -4 addr show 2>/dev/null \
        | ${pkgs.gawk}/bin/awk '$4 ~ /^10\.0\./ {print $2; exit}')
      if [ -n "$IP" ]; then
        ${pkgs.gnugrep}/bin/grep -q '^node-ip:' ${k3sConfigPath} || printf 'node-ip: %s\n' "$IP" >> ${k3sConfigPath}
      fi
      if [ -n "$IFACE" ]; then
        ${pkgs.gnugrep}/bin/grep -q '^flannel-iface:' ${k3sConfigPath} || printf 'flannel-iface: %s\n' "$IFACE" >> ${k3sConfigPath}
      fi
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

  services.k3s = {
    enable = true;
    role = "server";
  };

  systemd.services.k3s = {
    after = [ "network-online.target" "cloud-final.service" "k3s-cluster-config-augment.service" ];
    wants = [ "network-online.target" "k3s-cluster-config-augment.service" ];
    serviceConfig.ExecStart = lib.mkForce "${k3sLauncher}";
  };

  system.stateVersion = "25.05";
}
