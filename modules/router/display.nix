{ pkgs, ... }:
{
  hardware.graphics.enable = true;

  fonts.enableDefaultPackages = true;
  fonts.packages = with pkgs; [
    dejavu_fonts
    noto-fonts
  ];
}
