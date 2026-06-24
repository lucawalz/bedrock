{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.kioskConsole;

  compositor = pkgs.labwc;

  kioskUser = "kiosk";
  dashboardUrl = "https://grafana.syslabs.dev/d/wallbar/wall-status?kiosk&refresh=30s&theme=dark";
  idleTimeoutSeconds = 600;

  output = "HDMI-A-1";
  mode = "1280x400";
  transform = "normal";

  browser = lib.getExe pkgs.chromium;

  labwcConfigDir = "/etc/labwc";

  applyOutput = "${pkgs.wlr-randr}/bin/wlr-randr --output ${output} --on --mode ${mode} --transform ${transform}";

  dashboardArg = lib.escapeShellArg dashboardUrl;
  dashboardUrlXml = builtins.replaceStrings [ "&" ] [ "&amp;" ] dashboardUrl;

  autostart = pkgs.writeShellScript "labwc-autostart" ''
    ${applyOutput}
    ${pkgs.wbg}/bin/wbg --color 1d2021 &
    ${pkgs.swayidle}/bin/swayidle -w \
      timeout ${toString idleTimeoutSeconds} '${pkgs.wlr-randr}/bin/wlr-randr --output ${output} --off' \
      resume '${applyOutput}' &
    deadline=$((SECONDS + 150))
    while [ "$SECONDS" -lt "$deadline" ]; do
      ${pkgs.curl}/bin/curl -sf -o /dev/null --max-time 4 ${dashboardArg} && break
      sleep 3
    done
    ${browser} --ozone-platform=wayland --noerrdialogs --disable-infobars --disable-session-crashed-bubble --kiosk ${dashboardArg} &
  '';

  rcXml = pkgs.writeText "labwc-rc.xml" ''
    <?xml version="1.0"?>
    <labwc_config>
      <core>
        <gap>0</gap>
      </core>
      <keyboard>
        <keybind key="W-Return">
          <action name="Execute" command="${lib.getExe pkgs.foot}" />
        </keybind>
        <keybind key="W-d">
          <action name="Execute" command="${lib.getExe pkgs.fuzzel}" />
        </keybind>
      </keyboard>
    </labwc_config>
  '';

  menuXml = pkgs.writeText "labwc-menu.xml" ''
    <?xml version="1.0"?>
    <openbox_menu>
      <menu id="root-menu" label="labwc">
        <item label="Terminal">
          <action name="Execute" command="${lib.getExe pkgs.foot}" />
        </item>
        <item label="Launcher">
          <action name="Execute" command="${lib.getExe pkgs.fuzzel}" />
        </item>
        <item label="Reload dashboard">
          <action name="Execute" command="${browser} --ozone-platform=wayland --kiosk '${dashboardUrlXml}'" />
        </item>
      </menu>
    </openbox_menu>
  '';

  session = pkgs.writeShellScript "kiosk-session" ''
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_SESSION_TYPE=wayland
    exec ${compositor}/bin/labwc -C ${labwcConfigDir}/labwc
  '';
in
{
  options.services.kioskConsole.enable = lib.mkEnableOption "kiosk Wayland console on the bar display";

  config = lib.mkIf cfg.enable {
    programs.labwc.enable = true;

    security.polkit.enable = true;
    services.dbus.enable = true;

    users.users.${kioskUser} = {
      isNormalUser = true;
      home = "/home/${kioskUser}";
    };

    services.greetd = {
      enable = true;
      settings = {
        initial_session = {
          command = "${session}";
          user = kioskUser;
        };
        default_session = {
          command = "${lib.getExe pkgs.tuigreet} --time --remember --cmd ${session}";
          user = "greeter";
        };
      };
    };

    environment = {
      etc = {
        "labwc/labwc/autostart".source = autostart;
        "labwc/labwc/rc.xml".source = rcXml;
        "labwc/labwc/menu.xml".source = menuXml;
      };
      systemPackages = [
        compositor
        pkgs.foot
        pkgs.fuzzel
        pkgs.chromium
        pkgs.swayidle
        pkgs.wbg
        pkgs.wlr-randr
        pkgs.libdrm
        pkgs.edid-decode
      ];
    };
  };
}
