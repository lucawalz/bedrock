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

  outputs = { self, nixpkgs, disko, agenix, ... }:
  let
    lib = import ./lib { inherit nixpkgs self disko agenix; };
  in {
    nixosConfigurations = {
      master   = lib.mkHost { hostname = "master"; };
      worker-1 = lib.mkHost { hostname = "worker-1"; };
    };

    devShells.x86_64-linux.default = let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
      };
      kubeHelm = pkgs.wrapHelm pkgs.kubernetes-helm {
        plugins = with pkgs.kubernetes-helmPlugins; [
          helm-secrets
          helm-diff
          helm-s3
          helm-git
        ];
      };
    in pkgs.mkShell {
      packages = with pkgs; [
        kubectl
        kubeHelm
        fluxcd
        sops
        age
        nixos-rebuild
        nix-prefetch-git
        gnumake
        git
      ];
    };
  };
}

