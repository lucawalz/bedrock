{
  description = "NixOS homelab configuration with K3s cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      agenix,
      ...
    }:
    let
      lib = import ./lib {
        inherit
          nixpkgs
          self
          disko
          agenix
          ;
      };
      formatterSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      devShellPackages =
        pkgs: with pkgs; [
          kubectl
          kubernetes-helm
          fluxcd
          sops
          age
          nixos-rebuild
          git
          yq-go
          prometheus.cli
          jq
          curl
          coreutils
          python3
          bashInteractive
        ];
      devShellExtraPackages = {
        x86_64-linux =
          pkgs: with pkgs; [
            nix-prefetch-git
            gnumake
          ];
        aarch64-darwin =
          pkgs: with pkgs; [
            nixos-anywhere
            zstd
          ];
      };
    in
    {
      formatter = nixpkgs.lib.genAttrs formatterSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      nixosConfigurations = lib.clusterNodes // {
        router = lib.mkHost {
          hostname = "router";
          system = "aarch64-linux";
          baseline = false;
        };
        cluster-node = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            disko.nixosModules.disko
            ./modules/k3s/cluster-node.nix
          ];
        };
        router-installer = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            ./hosts/router-installer.nix
          ];
        };
      };

      devShells = nixpkgs.lib.mapAttrs (
        system: extraPackages:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            name = "bedrock";
            packages = devShellPackages pkgs ++ extraPackages pkgs;
          };
        }
      ) devShellExtraPackages;
    };
}
