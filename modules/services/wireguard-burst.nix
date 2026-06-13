{ config, lib, pkgs, ... }:
{
  systemd.services.wireguard-burst-up = {
    description = "Bring up wg0 tunnel to the hub from injected key material";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStartSec = 120;
    };
    script = ''
      set -eu
      ADDRESS=$(cat /etc/horizon/wg-address)
      HUBKEY=$(cat /etc/horizon/wg-hub-public-key)
      ip="${pkgs.iproute2}/bin/ip"
      wg="${pkgs.wireguard-tools}/bin/wg"
      $ip link show wg0 >/dev/null 2>&1 || $ip link add wg0 type wireguard
      $wg set wg0 private-key /etc/horizon/wg-private listen-port 51820
      $wg set wg0 peer "$HUBKEY" allowed-ips 192.168.20.0/24,10.100.0.0/24
      $ip addr show dev wg0 | ${pkgs.gnugrep}/bin/grep -qw "$ADDRESS" || $ip addr add "$ADDRESS" dev wg0
      $ip link set wg0 up
    '';
  };

  networking.firewall.trustedInterfaces = [ "wg0" ];
}
