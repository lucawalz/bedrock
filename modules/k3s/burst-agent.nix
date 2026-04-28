{ config, lib, pkgs, ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        bios = {
          priority = 1;
          start = "1M";
          end = "2M";
          type = "EF02";
        };
        ESP = {
          priority = 2;
          start = "2M";
          end = "514M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };

  boot.initrd.availableKernelModules = [ "ahci" "sd_mod" "virtio_pci" "virtio_scsi" "virtio_blk" ];

  networking.hostName = "hetzner-burst-node";
  networking.firewall.allowedTCPPorts = [ 10250 ];
  networking.firewall.allowedUDPPorts = [ 8472 41641 ];
  networking.firewall.checkReversePath = "loose";
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  services.tailscale = {
    enable = true;
    interfaceName = "tailscale0";
    authKeyFile = "/etc/horizon/ts-auth-key";
    extraUpFlags = [ "--accept-dns=false" ];
  };

  systemd.services.tailscale-autoconnect.enable = lib.mkForce false;

  systemd.services.tailscaled-headscale-login = {
    description = "Configure tailscaled to log in to self-hosted headscale";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "tailscaled.service" "network-online.target" ];
    before = [ "tailscale-autoconnect.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      if [ ! -f /etc/horizon/headscale-server-url ]; then
        echo "missing /etc/horizon/headscale-server-url" >&2
        exit 1
      fi
      LOGIN_SERVER=$(cat /etc/horizon/headscale-server-url)
      AUTH_KEY=$(cat /etc/horizon/ts-auth-key)
      ${pkgs.tailscale}/bin/tailscale up \
        --login-server="$LOGIN_SERVER" \
        --auth-key="$AUTH_KEY" \
        --accept-dns=false \
        --hostname="$(hostname)" \
        --reset
    '';
  };

  systemd.services.k3s-config-writer = {
    description = "Write /etc/rancher/k3s/config.yaml after tailscale0 IP is available";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled-headscale-login.service" ];
    wants = [ "tailscaled-headscale-login.service" ];
    before = [ "k3s.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      DEADLINE=$(( $(date +%s) + 120 ))
      while :; do
        IP=$(${pkgs.tailscale}/bin/tailscale ip -4 2>/dev/null || true)
        case "$IP" in
          100.*) break ;;
        esac
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then
          echo "tailscale0 IP not assigned within 120s" >&2
          exit 1
        fi
        sleep 2
      done
      mkdir -p /etc/rancher/k3s
      {
        echo "node-ip: $IP"
        echo "flannel-iface: tailscale0"
      } > /etc/rancher/k3s/config.yaml
      chmod 600 /etc/rancher/k3s/config.yaml
    '';
  };

  systemd.services.k3s-server-addr-writer = {
    description = "Write K3S_URL environment file from /etc/horizon/k3s-url";
    wantedBy = [ "multi-user.target" ];
    before = [ "k3s.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      K3S_URL=$(cat /etc/horizon/k3s-url)
      printf 'K3S_URL=%s\n' "$K3S_URL" > /run/k3s.env
      chmod 600 /run/k3s.env
    '';
  };

  services.k3s = {
    enable = true;
    role = "agent";
    tokenFile = "/etc/horizon/k3s-token";
  };

  systemd.services.k3s = {
    after = [ "k3s-config-writer.service" "tailscaled-headscale-login.service" "k3s-server-addr-writer.service" ];
    wants = [ "k3s-config-writer.service" "tailscaled-headscale-login.service" "k3s-server-addr-writer.service" ];
    serviceConfig.EnvironmentFile = lib.mkForce "/run/k3s.env";
  };

  system.stateVersion = "25.05";
}
