{ lib, pkgs, ... }:
let
  tailscaleAuthKeyPath = "/etc/tailscale/authkey";
  tailscaleIface = "tailscale0";
  k3sConfigPath = "/etc/rancher/k3s/config.yaml";
  airGappedInstallScript = pkgs.writeShellScript "k3s-airgapped-install" ''
    exit 0
  '';
  configWaitSeconds = 540;
  tailscaleWaitSeconds = 540;
in
{
  imports = [ ./hetzner-scaffolding.nix ];

  networking.hostName = "hetzner-capi-node";
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

  systemd.tmpfiles.rules = [
    "L+ /opt/install.sh - - - - ${airGappedInstallScript}"
  ];

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    authKeyFile = tailscaleAuthKeyPath;
    extraUpFlags = [
      "--accept-routes"
      "--advertise-tags=tag:burst"
      "--hostname=hetzner-capi-node"
    ];
  };

  systemd.services.tailscaled-autoconnect = {
    after = [ "tailscaled.service" ];
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

  systemd.services.k3s-capi-config-augment = {
    description = "Augment CAPI-written k3s config with tailscale node networking";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled-autoconnect.service" ];
    wants = [ "tailscaled-autoconnect.service" ];
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
    '';
  };

  services.k3s = {
    enable = true;
    role = "agent";
  };

  systemd.services.k3s = {
    after = [ "tailscaled-autoconnect.service" "k3s-capi-config-augment.service" ];
    wants = [ "tailscaled-autoconnect.service" "k3s-capi-config-augment.service" ];
  };

  system.stateVersion = "25.05";
}
