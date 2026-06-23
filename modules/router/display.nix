{
  pkgs,
  lib,
  config,
  ...
}:
let
  wisecocoEdid = pkgs.runCommand "wisecoco-1280x400-edid" { } ''
    install -Dm444 ${./wisecoco-1280x400.bin} "$out/lib/firmware/edid/wisecoco-1280x400.bin"
  '';
in
{
  config = lib.mkIf config.services.kioskConsole.enable {
    hardware.graphics.enable = true;

    hardware.display = {
      edid.packages = [ wisecocoEdid ];
      outputs."HDMI-A-1" = {
        edid = "wisecoco-1280x400.bin";
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
