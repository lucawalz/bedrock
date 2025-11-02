# K3s worker node (agent)

{ config, pkgs, meta, ... }:

{
  imports = [
    # ./disko-config.nix  # Commented out - using traditional filesystem definitions instead
    ./hardware-configuration.nix
    ../common.nix
    ../../roles/k3s-agent.nix
    ../../roles/common-services.nix
  ];

  networking.hostName = "worker-1";
  
  # Configure static IP if needed (adjust based on your network)
  # networking.interfaces.eth0.ipv4.addresses = [{
  #   address = "192.168.1.11";
  #   prefixLength = 24;
  # }];
  # networking.defaultGateway = "192.168.1.1";
  # networking.nameservers = [ "192.168.1.1" "8.8.8.8" ];

  system.stateVersion = "25.05";
}

