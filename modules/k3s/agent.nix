# K3s worker (agent) module
{ config, lib, pkgs, meta, secretsDir ? ../../secrets, ... }:

let
  # Parameterized instead of hardcoded!
  serverHost = lib.mkDefault "master";
in
{
  imports = [ ./common.nix ];

  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://${serverHost}:6443";
    tokenFile = config.age.secrets.k3s-token.path;
  };

  # Firewall ports for K3s worker
  networking.firewall.allowedTCPPorts = [ 10250 ];
  networking.firewall.allowedUDPPorts = [ 8472 ];  # Flannel VXLAN
}
