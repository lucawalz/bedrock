{
  pkgs,
  lib,
  config,
  ...
}:
{
  config = lib.mkIf config.services.kioskConsole.enable {
    hardware.graphics.enable = true;

    hardware.display = {
      edid.modelines."1280x400_60" = "41.50  1280 1300 1340 1441  400 415 419 480  +hsync +vsync";
      outputs."HDMI-A-1" = {
        edid = "1280x400_60.bin";
        mode = "e";
      };
    };

    fonts = {
      enableDefaultPackages = true;
      packages = with pkgs; [
        dejavu_fonts
        noto-fonts
      ];
    };
  };
}
