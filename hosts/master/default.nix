{ config, lib, pkgs, meta, ... }:
let
  kubeHelm = pkgs.wrapHelm pkgs.kubernetes-helm {
    plugins = with pkgs.kubernetes-helmPlugins; [
      helm-secrets
      helm-diff
      helm-s3
      helm-git
    ];
  };
in
{
  imports = [
    ./disko-config.nix
    ./hardware-configuration.nix
    ../common
    ../../modules/k3s/server.nix
    ../../modules/services/storage.nix
    ../../modules/services/rollback-gate.nix
    ../../modules/services/tailscale.nix
  ];

  networking.hostName = "master";
  system.stateVersion = "25.05";

  environment.systemPackages = [ kubeHelm pkgs.fluxcd pkgs.sops ];
  environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

  # hardware-configuration.nix and disko both define these — force UUID-based values to win
  fileSystems."/".device = lib.mkForce "/dev/disk/by-uuid/6fbd4057-aa2d-4134-9a7d-c4d1e109eb7b";
  fileSystems."/boot".device = lib.mkForce "/dev/disk/by-uuid/1A21-BED9";
}

