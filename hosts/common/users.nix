{ meta, ... }:
let
  lucaKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHoKFFTFmJR1CSAq55TwXHbUPTxSK847qZL0W6r/ZUV9 luca@macbook";
  estateRootKey = "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBDg/tm+t8N9fNwMvAVCKJGfGq/H+FADwbi68xYrVH4bmWrjTpUjd81+FbP8tUKrO2piZQQeDyLQvavJdjdNb3hAAAAAEc3NoOg== estate-root";
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
