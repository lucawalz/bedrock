{ lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
  ];

  # hardware-configuration.nix and disko both define these — force UUID-based values to win
  fileSystems."/".device = lib.mkForce "/dev/disk/by-uuid/6fbd4057-aa2d-4134-9a7d-c4d1e109eb7b";
  fileSystems."/boot".device = lib.mkForce "/dev/disk/by-uuid/1A21-BED9";
}
