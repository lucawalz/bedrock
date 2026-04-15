{ config, pkgs, meta, ... }:
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
    ../../modules/services/monitoring.nix
    ../../modules/services/storage.nix
  ];

  networking.hostName = "master";
  system.stateVersion = "25.05";

  environment.systemPackages = [ kubeHelm pkgs.fluxcd pkgs.sops ];
  environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
}

