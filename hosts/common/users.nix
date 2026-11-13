{ lib, meta, ... }:
let
  estateRootKeys = [
    (lib.fileContents ./estate-root.pub)
  ]
  ++ lib.optional (builtins.pathExists ./estate-root-next.pub) (
    lib.fileContents ./estate-root-next.pub
  );
  breakglassKey = lib.fileContents ./estate-breakglass.pub;
in
{
  users.users.${meta.hostname} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = estateRootKeys;
  };

  users.users.root.openssh.authorizedKeys.keys = estateRootKeys ++ [ breakglassKey ];

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
