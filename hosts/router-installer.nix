{ modulesPath, ... }:
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
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHoKFFTFmJR1CSAq55TwXHbUPTxSK847qZL0W6r/ZUV9 luca@macbook"
    "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBDg/tm+t8N9fNwMvAVCKJGfGq/H+FADwbi68xYrVH4bmWrjTpUjd81+FbP8tUKrO2piZQQeDyLQvavJdjdNb3hAAAAAEc3NoOg== estate-root"
  ];

  system.stateVersion = "25.05";
}
