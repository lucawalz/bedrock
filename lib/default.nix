# Utility functions to reduce duplication in flake.nix
{
  nixpkgs,
  self,
  disko,
  agenix,
  ...
}:
let
  inventory = import ./inventory.nix;

  mkDiskoLayout = diskDevice: {
    disk.main = {
      type = "disk";
      device = diskDevice;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            priority = 1;
            name = "ESP";
            start = "1M";
            end = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
in
assert builtins.elem inventory.bootstrapControlPlane inventory.controlPlanes;
rec {
  inherit inventory;

  mkHost =
    {
      hostname,
      system ? "x86_64-linux",
      baseline ? true,
    }:
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        meta = { inherit hostname; };
        secretsDir = "${self}/secrets";
        inherit inventory;
      };
      modules = [
        disko.nixosModules.disko
        agenix.nixosModules.default
        ../hosts/${hostname}
      ]
      ++ nixpkgs.lib.optional baseline ../hosts/common;
    };

  mkNode =
    {
      hostname,
      diskDevice ? "/dev/nvme0n1",
      system ? "x86_64-linux",
    }:
    let
      node =
        if builtins.hasAttr hostname inventory.nodes then
          inventory.nodes.${hostname}
        else
          throw "mkNode: hostname '${hostname}' is not present in the inventory";
      isServer = node.role == "server";
      hostDir = ../hosts/${hostname};
    in
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        meta = { inherit hostname; };
        secretsDir = "${self}/secrets";
        inherit inventory;
      };
      modules = [
        disko.nixosModules.disko
        agenix.nixosModules.default
        ../hosts/common
      ]
      ++ nixpkgs.lib.optional (builtins.pathExists hostDir) hostDir
      ++ [
        (
          {
            config,
            secretsDir,
            pkgs,
            ...
          }:
          {
            imports = [
              (if isServer then ../modules/k3s/server.nix else ../modules/k3s/agent.nix)
              ../modules/services/storage.nix
              ../modules/tailscale/client.nix
            ];

            networking.hostName = hostname;
            system.stateVersion = "25.05";

            services.k3s.extraFlags = nixpkgs.lib.mkIf (!isServer) [
              "--node-ip=${node.address}"
            ];

            age.secrets.tailscale-authkey = {
              file = "${secretsDir}/tailscale-authkey-${hostname}.age";
              mode = "0400";
              owner = "root";
              group = "root";
            };

            bedrock.tailscaleClient = {
              enable = true;
              inherit hostname;
              authKeyFile = config.age.secrets.tailscale-authkey.path;
              tag = "tag:cluster";
            };

            boot.binfmt.emulatedSystems = nixpkgs.lib.mkIf isServer [ "aarch64-linux" ];

            environment.systemPackages = nixpkgs.lib.mkIf isServer [
              (pkgs.wrapHelm pkgs.kubernetes-helm {
                plugins = with pkgs.kubernetes-helmPlugins; [
                  helm-secrets
                  helm-diff
                  helm-s3
                  helm-git
                ];
              })
              pkgs.fluxcd
              pkgs.sops
            ];
            environment.variables.KUBECONFIG = nixpkgs.lib.mkIf isServer "/etc/rancher/k3s/k3s.yaml";

            disko.devices = mkDiskoLayout diskDevice;
          }
        )
      ];
    };

  clusterNodes = nixpkgs.lib.genAttrs (builtins.attrNames inventory.nodes) (
    hostname: mkNode { inherit hostname; }
  );
}
