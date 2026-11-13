{ lib, modulesPath, ... }:
{
  imports = [ "${modulesPath}/installer/sd-card/sd-image-aarch64.nix" ];

  nixpkgs.hostPlatform = "aarch64-linux";

  networking.hostName = "router";

  boot.kernelParams = [
    "console=ttyS0,115200"
    "console=tty1"
  ];

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  users.users.root.openssh.authorizedKeys.keys = [
    (lib.fileContents ./common/estate-root.pub)
    (lib.fileContents ./common/estate-breakglass.pub)
  ]
  ++ lib.optional (builtins.pathExists ./common/estate-root-next.pub) (
    lib.fileContents ./common/estate-root-next.pub
  );

  system.stateVersion = "25.05";
}
