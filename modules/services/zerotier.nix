{ config, lib, pkgs, ... }:
{
  services.zerotierone = {
    enable = true;
  };

  systemd.services.zerotier-join = {
    description = "Join ZeroTier network from /etc/horizon/zerotier-network-id";
    wantedBy = [ "multi-user.target" ];
    after = [ "zerotierone.service" "network-online.target" ];
    wants = [ "zerotierone.service" "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = 120;
    };
    script = ''
      set -eu
      if [ ! -f /etc/horizon/zerotier-network-id ]; then
        echo "missing /etc/horizon/zerotier-network-id" >&2
        exit 1
      fi
      NWID=$(cat /etc/horizon/zerotier-network-id)
      DEADLINE=$(( $(date +%s) + 60 ))
      until ${pkgs.zerotierone}/bin/zerotier-cli info >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then
          echo "zerotierone service not responding within 60s" >&2
          exit 1
        fi
        sleep 1
      done
      ${pkgs.zerotierone}/bin/zerotier-cli join "$NWID" || true
    '';
  };

  networking.firewall.allowedUDPPorts = [ 9993 ];
  networking.firewall.trustedInterfaces = [ "zt+" ];
}
