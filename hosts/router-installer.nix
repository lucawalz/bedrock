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
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJ6Jg18p6w/1hBEjhG7zNDdL30R8ihHZcaU/arZ346cAGIewmSqMYXyKnfOoP4tFjZtejafeESD3IQxrybmx74A= estate-root"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMfTCbT6YlvmxEvMaTq+W4TMpOtPo+cRAnknC5T0ItWE estate-breakglass"
  ];

  system.stateVersion = "25.05";
}
