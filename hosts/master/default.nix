{ config, pkgs, meta, ... }:
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
}

