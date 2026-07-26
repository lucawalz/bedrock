{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    neovim
    cifs-utils
    nfs-utils
    git
    age
    htop
    tmux
    tree
  ];
}
