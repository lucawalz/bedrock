_:
{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  programs.ssh.extraConfig = ''
    Host github.com
      IdentityFile /etc/ssh/ssh_host_ed25519_key
      IdentitiesOnly yes
  '';
}
