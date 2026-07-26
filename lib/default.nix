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
in
{
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

  mkWorker =
    {
      workerId,
      diskDevice ? "/dev/nvme0n1",
      system ? "x86_64-linux",
    }:
    let
      hostname = "worker-${toString workerId}";
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
        ({ ... }: {
          imports = [
            ../modules/k3s/agent.nix
            ../modules/services/storage.nix
          ];

          networking.hostName = hostname;
          system.stateVersion = "25.05";

          services.k3s.extraFlags = [ "--node-ip=${inventory.nodes.${hostname}}" ];

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
