{
  pkgs,
  lib,
  config,
  ...
}:
let
  panelEdid = ./wisecoco-edid.bin;
in
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

    systemd.services.bar-panel-edid = {
      before = [ "greetd.service" ];
      wantedBy = [ "greetd.service" ];
      after = [ "sys-kernel-debug.mount" ];
      unitConfig.ConditionPathIsMountPoint = "/sys/kernel/debug";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        for override in /sys/kernel/debug/dri/[0-9]*/HDMI-A-1/edid_override; do
          [ -w "$override" ] && cat ${panelEdid} > "$override" || true
        done
        for status in /sys/class/drm/card[0-9]*-HDMI-A-1/status; do
          [ -w "$status" ] && echo detect > "$status" || true
        done
      '';
    };
  };
}
