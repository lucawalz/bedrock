{ lib, meta, ... }:
let
  estateRootKey = lib.fileContents ./estate-root.pub;
  breakglassKey = lib.fileContents ./estate-breakglass.pub;
in
{
  users.users.${meta.hostname} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ estateRootKey ];
  };

  users.users.root.openssh.authorizedKeys.keys = [
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
