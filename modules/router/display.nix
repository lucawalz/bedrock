{
  pkgs,
  lib,
  config,
  ...
}:
let
  edidName = "wisecoco-400x1280.bin";
  edidFirmware = pkgs.runCommand "wisecoco-edid-firmware" { } ''
    install -Dm444 ${./wisecoco-400x1280.bin} "$out/lib/firmware/edid/${edidName}"
  '';
  edidInitrd = pkgs.runCommand "wisecoco-edid-initrd" { } ''
    mkdir -p root/lib/firmware/edid
    cp ${./wisecoco-400x1280.bin} root/lib/firmware/edid/${edidName}
    ( cd root && find . -print0 | sort -z | ${pkgs.cpio}/bin/cpio -o -H newc --null ) > $out
  '';
in
{
  config = lib.mkIf config.services.kioskConsole.enable {
    hardware.graphics.enable = true;

    hardware.firmware = [ edidFirmware ];
    boot.initrd.prepend = [ "${edidInitrd}" ];
    boot.kernelParams = [
      "video=HDMI-A-1:e"
      "drm.edid_firmware=HDMI-A-1:edid/${edidName}"
    ];

    fonts = {
      enableDefaultPackages = true;
      packages = with pkgs; [
        dejavu_fonts
        noto-fonts
      ];
    };
  };
}
