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
}
