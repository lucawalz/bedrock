# Utility functions to reduce duplication in flake.nix
{ nixpkgs, self, disko, agenix, ... }:
let
  standbySubnetRouterWorkerId = 2;
in
{
  mkHost = { hostname, system ? "x86_64-linux", baseline ? true }:
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        meta = { inherit hostname; };
        secretsDir = "${self}/secrets";
      };
      modules = [
        disko.nixosModules.disko
        agenix.nixosModules.default
        ../hosts/${hostname}
      ] ++ nixpkgs.lib.optional baseline ../hosts/common;
    };

  mkWorker = { workerId, diskDevice ? "/dev/nvme0n1", system ? "x86_64-linux" }:
    let
      hostname = "worker-${toString workerId}";
    in
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        meta = { inherit hostname; };
        secretsDir = "${self}/secrets";
      };
      modules = [
        disko.nixosModules.disko
        agenix.nixosModules.default
        ../hosts/common
        ({ config, lib, secretsDir, ... }: {
          imports = [
            ../modules/k3s/agent.nix
            ../modules/services/storage.nix
            ../modules/tailscale/subnet-router.nix
          ];

          networking.hostName = hostname;
          system.stateVersion = "25.05";

          services.k3s.extraFlags = [ "--node-ip=10.20.0.1${toString workerId}" ];

          age.secrets = lib.mkIf (workerId == standbySubnetRouterWorkerId) {
            "tailscale-authkey-${hostname}" = {
              file = "${secretsDir}/tailscale-authkey-${hostname}.age";
              mode = "0400";
              owner = "root";
              group = "root";
            };
          };

          bedrock.tailscaleSubnetRouter = lib.mkIf (workerId == standbySubnetRouterWorkerId) {
            enable = true;
            hostname = hostname;
            authKeyFile = config.age.secrets."tailscale-authkey-${hostname}".path;
            acceptRoutes = false;
          };

          disko.devices = {
            disk = {
              main = {
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
          };
        })
      ];
    };
}
