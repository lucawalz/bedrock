{ pkgs, ... }:
{
  hardware.graphics.enable = true;

  fonts = {
    enableDefaultPackages = true;
    packages = with pkgs; [
      dejavu_fonts
      noto-fonts
    ];
  };
}
