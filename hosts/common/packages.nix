{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    neovim
    k3s
    cifs-utils
    nfs-utils
    git
    age
    htop
    tmux
    tree
  ];
}
