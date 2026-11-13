{ meta, ... }:
let
  lucaKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHoKFFTFmJR1CSAq55TwXHbUPTxSK847qZL0W6r/ZUV9 luca@macbook";
  estateRootKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJ6Jg18p6w/1hBEjhG7zNDdL30R8ihHZcaU/arZ346cAGIewmSqMYXyKnfOoP4tFjZtejafeESD3IQxrybmx74A= estate-root";
  breakglassKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMfTCbT6YlvmxEvMaTq+W4TMpOtPo+cRAnknC5T0ItWE estate-breakglass";
in
{
  users.users.${meta.hostname} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      lucaKey
      estateRootKey
    ];
  };

  users.users.root.openssh.authorizedKeys.keys = [
    lucaKey
    estateRootKey
    breakglassKey
  ];

  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    authorizedKeysInHomedir = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AllowAgentForwarding = false;
    };
  };
}
