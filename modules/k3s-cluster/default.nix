# Custom K3s cluster management module
# This is an example of a custom module - adjust as needed

{ config, lib, pkgs, meta, ... }:

with lib;

{
  options = {
    k3sCluster = {
      enable = mkEnableOption "K3s cluster configuration";
      
      role = mkOption {
        type = types.enum [ "server" "agent" ];
        description = "K3s node role";
      };
      
      serverAddr = mkOption {
        type = types.str;
        default = "https://master:6443";
        description = "K3s server address (for agents)";
      };
      
      tokenFile = mkOption {
        type = types.path;
        description = "Path to K3s token file";
      };
    };
  };

  config = mkIf config.k3sCluster.enable {
    services.k3s = {
      enable = true;
      role = config.k3sCluster.role;
      serverAddr = if config.k3sCluster.role == "server" then "" else config.k3sCluster.serverAddr;
      tokenFile = config.k3sCluster.tokenFile;
      extraFlags = if config.k3sCluster.role == "server" then [
        "--write-kubeconfig-mode=0644"
        "--disable=servicelb"
        "--disable=traefik"
        "--disable=local-storage"
      ] else [];
      clusterInit = (config.k3sCluster.role == "server");
    };
  };
}

