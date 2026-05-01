{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../services/zerotier.nix
  ];

  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
        };
        ESP = {
          size = "512M";
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

  boot.loader.grub.enable = true;
  boot.initrd.availableKernelModules = [ "ahci" "sd_mod" "sr_mod" "virtio_pci" "virtio_scsi" "virtio_blk" ];

  networking.hostName = "hetzner-burst-node";
  networking.useDHCP = true;
  networking.firewall.allowedTCPPorts = [ 10250 ];
  networking.firewall.allowedUDPPorts = [ 8472 ];
  networking.firewall.checkReversePath = "loose";

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      AuthorizedKeysFile = "/etc/horizon/ssh-authorized-keys";
    };
  };

  systemd.services.k3s-config-writer = {
    description = "Write /etc/rancher/k3s/config.yaml after the ZeroTier interface gets an IP";
    wantedBy = [ "multi-user.target" ];
    after = [ "zerotier-join.service" ];
    wants = [ "zerotier-join.service" ];
    before = [ "k3s.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      DEADLINE=$(( $(date +%s) + 120 ))
      while :; do
        IFACE=$(${pkgs.iproute2}/bin/ip -o link show | ${pkgs.gawk}/bin/awk '$2 ~ /^zt/ {gsub(/:$/, "", $2); print $2; exit}')
        if [ -n "$IFACE" ]; then
          IP=$(${pkgs.iproute2}/bin/ip -o -4 addr show "$IFACE" 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $4}' | ${pkgs.coreutils}/bin/cut -d/ -f1 | ${pkgs.coreutils}/bin/head -1)
          if [ -n "$IP" ]; then
            break
          fi
        fi
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then
          echo "ZeroTier interface IP not assigned within 120s" >&2
          exit 1
        fi
        sleep 2
      done
      mkdir -p /etc/rancher/k3s
      {
        echo "node-ip: $IP"
        echo "flannel-iface: $IFACE"
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
    after = [ "k3s-config-writer.service" "zerotier-join.service" "k3s-server-addr-writer.service" ];
    wants = [ "k3s-config-writer.service" "zerotier-join.service" "k3s-server-addr-writer.service" ];
    serviceConfig.EnvironmentFile = lib.mkForce "/run/k3s.env";
  };

  system.stateVersion = "25.05";
}
