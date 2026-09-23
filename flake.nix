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
      nixpkgs,
      disko,
      agenix,
      ...
    }:
    let
      lib = import ./lib {
        inherit
          nixpkgs
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
          kubeconform
          kustomize
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
        router = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = {
            meta.hostname = "router";
            inherit (lib) inventory secretsDir;
          };
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/router
          ];
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
