{ config, lib, pkgs, secretsDir ? ../../secrets, ... }:
{
  age.secrets.tailscale-auth-key = {
    file = "${secretsDir}/tailscale-auth-key.age";
    mode = "0400";
    owner = "root";
  };

  services.tailscale = {
    enable = true;
    interfaceName = "tailscale0";
  };

  systemd.services.tailscale-autoconnect.enable = lib.mkForce false;

  systemd.services.tailscaled-headscale-login = {
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "tailscaled.service" "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      AUTH_KEY=$(cat ${config.age.secrets.tailscale-auth-key.path})
      ${pkgs.tailscale}/bin/tailscale up \
        --login-server=https://headscale.syslabs.dev \
        --auth-key="$AUTH_KEY" \
        --accept-dns=false \
        --reset
    '';
  };

  networking.firewall.allowedUDPPorts = [ 41641 ];
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.checkReversePath = lib.mkDefault "loose";
}
