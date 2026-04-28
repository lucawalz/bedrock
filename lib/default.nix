# Utility functions to reduce duplication in flake.nix
{ nixpkgs, self, disko, agenix, ... }:
{
  mkHost = { hostname, system ? "x86_64-linux" }:
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
      ];
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
        ({ config, lib, ... }: {
          imports = [
            ../hosts/common
            ../modules/k3s/agent.nix
            ../modules/services/monitoring.nix
            ../modules/services/storage.nix
            ../modules/services/rollback-gate.nix
            ../modules/services/tailscale.nix
          ];

          networking.hostName = hostname;
          system.stateVersion = "25.05";

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
