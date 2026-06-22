{
  pkgs,
  lib,
  config,
  ...
}:
{
  config = lib.mkIf config.services.kioskConsole.enable {
    hardware.graphics.enable = true;

    fonts = {
      enableDefaultPackages = true;
      packages = with pkgs; [
        dejavu_fonts
        noto-fonts
      ];
    };
  };
}
