{ config, pkgs, meta, ... }:
{
  imports = [
    ./disko-config.nix
    ./hardware-configuration.nix
    ../common
    ../../modules/k3s/agent.nix
    ../../modules/services/monitoring.nix
    ../../modules/services/storage.nix
  ];

  networking.hostName = "worker-1";
  system.stateVersion = "25.05";
}

