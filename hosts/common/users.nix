{ meta, ... }:
let
  lucaKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHoKFFTFmJR1CSAq55TwXHbUPTxSK847qZL0W6r/ZUV9 luca@macbook";
in
{
  users.users.${meta.hostname} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ lucaKey ];
  };

  users.users.root.openssh.authorizedKeys.keys = [ lucaKey ];

  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;
}
