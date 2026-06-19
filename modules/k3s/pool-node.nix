{ lib, pkgs, ... }:
let
  tailscaleAuthKeyPath = "/etc/tailscale/authkey";
  tailscaleIface = "tailscale0";
  k3sConfigPath = "/etc/rancher/k3s/config.yaml";
  metadataBase = "http://169.254.169.254/hetzner/v1/metadata";
  airGappedInstallScript = pkgs.writeShellScript "k3s-airgapped-install" ''
    exit 0
  '';
  tailscaleWaitSeconds = 540;
in
{
  imports = [ ./hetzner-scaffolding.nix ];

  networking.hostName = "";
  networking.useDHCP = true;
  networking.firewall.allowedTCPPorts = [ 10250 ];
  networking.firewall.allowedUDPPorts = [ 8472 ];
  networking.firewall.checkReversePath = "loose";
  networking.firewall.trustedInterfaces = [ tailscaleIface ];

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
    name = "iqn.2016-04.com.open-iscsi:bedrock-pool-node";
  };

  systemd.tmpfiles.rules = [
    "L+ /opt/install.sh - - - - ${airGappedInstallScript}"
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];

  systemd.services.hetzner-set-hostname = {
    description = "Set the node hostname from Hetzner metadata";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    before = [ "tailscaled-autoconnect.service" "k3s-config-augment.service" "k3s.service" ];
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
        if [ -n "$NAME" ]; then break; fi
        i=$((i+1))
        sleep 2
      done
      if [ -n "$NAME" ]; then
        ${pkgs.systemd}/bin/hostnamectl set-hostname "$NAME"
      fi
    '';
  };

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    authKeyFile = tailscaleAuthKeyPath;
    extraUpFlags = [
      "--accept-routes"
      "--advertise-tags=tag:burst"
    ];
  };

  systemd.services.tailscaled-autoconnect = {
    after = [ "tailscaled.service" "hetzner-set-hostname.service" ];
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

  systemd.services.k3s-config-augment = {
    description = "Augment user-data k3s config with tailscale node networking";
    wantedBy = [ "multi-user.target" ];
    after = [ "cloud-final.service" "tailscaled-autoconnect.service" ];
    wants = [ "cloud-final.service" "tailscaled-autoconnect.service" ];
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
      DEADLINE=$(( $(date +%s) + ${toString tailscaleWaitSeconds} ))
      while :; do
        IP=$(${pkgs.iproute2}/bin/ip -o -4 addr show ${tailscaleIface} 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $4}' | ${pkgs.coreutils}/bin/cut -d/ -f1 | ${pkgs.coreutils}/bin/head -1)
        if [ -n "$IP" ]; then
          break
        fi
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then
          echo "${tailscaleIface} IPv4 not assigned within ${toString tailscaleWaitSeconds}s" >&2
          exit 1
        fi
        sleep 2
      done
      ${pkgs.gnugrep}/bin/grep -q '^node-ip:' ${k3sConfigPath} || printf 'node-ip: %s\n' "$IP" >> ${k3sConfigPath}
      # flannel derives its VXLAN MTU from this iface (tailscale0 is 1280) so pod traffic over the tailnet does not fragment.
      ${pkgs.gnugrep}/bin/grep -q '^flannel-iface:' ${k3sConfigPath} || printf 'flannel-iface: %s\n' "${tailscaleIface}" >> ${k3sConfigPath}
      ${pkgs.gnused}/bin/sed -i '/- cloud-provider=external/d' ${k3sConfigPath}
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
    role = "agent";
  };

  systemd.services.k3s = {
    after = [ "tailscaled-autoconnect.service" "k3s-config-augment.service" ];
    wants = [ "tailscaled-autoconnect.service" "k3s-config-augment.service" ];
  };

  system.stateVersion = "25.05";
}
