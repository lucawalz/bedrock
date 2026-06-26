{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.kioskConsole;

  compositor = pkgs.labwc;

  transparentCursor =
    pkgs.runCommand "transparent-cursor-theme"
      {
        nativeBuildInputs = [
          pkgs.imagemagick
          pkgs.xcursorgen
        ];
      }
      ''
        cursors="$out/share/icons/transparent/cursors"
        mkdir -p "$cursors"
        magick -size 1x1 xc:transparent transparent.png
        echo "24 0 0 transparent.png" > transparent.cfg
        xcursorgen transparent.cfg "$cursors/left_ptr"
        printf '[Icon Theme]\nName=transparent\n' > "$out/share/icons/transparent/index.theme"
        for n in default text pointer wait watch progress help crosshair cross hand1 hand2 \
          xterm ibeam fleur move all-scroll not-allowed forbidden left_ptr_watch question_arrow \
          size_all sb_h_double_arrow sb_v_double_arrow top_side bottom_side left_side right_side \
          n-resize e-resize s-resize w-resize ns-resize ew-resize col-resize row-resize \
          nesw-resize nwse-resize zoom-in zoom-out copy alias no-drop grabbing openhand closedhand \
          vertical-text top_left_corner top_right_corner bottom_left_corner bottom_right_corner \
          sb_up_arrow sb_down_arrow sb_left_arrow sb_right_arrow context-menu pencil X_cursor; do
          ln -sf left_ptr "$cursors/$n"
        done
      '';

  kioskUser = "kiosk";
  dashboardUrl = "https://grafana.syslabs.dev/d/wallbar/wall-status?kiosk&theme=dark&refresh=30s&autofitpanels&from=now-15m&to=now";
  presenceTimeoutSeconds = 300;
  motionPin = 17;

  output = "HDMI-A-1";
  mode = "1280x400";
  transform = "normal";

  browser = lib.getExe pkgs.chromium;

  labwcConfigDir = "/etc/labwc";

  applyOutput = "${pkgs.wlr-randr}/bin/wlr-randr --output ${output} --on --mode ${mode} --transform ${transform}";
  offOutput = "${pkgs.wlr-randr}/bin/wlr-randr --output ${output} --off";

  motionChip = "gpiochip0";

  presenceWatch = pkgs.writeShellScript "presence-watch" ''
    awake=1
    last=$SECONDS
    while true; do
      if ${pkgs.libgpiod}/bin/gpioget -c ${motionChip} ${toString motionPin} 2>/dev/null | grep -q "=active"; then
        last=$SECONDS
        [ "$awake" = 0 ] && { ${applyOutput}; awake=1; }
      elif [ "$awake" = 1 ] && [ $(( SECONDS - last )) -ge ${toString presenceTimeoutSeconds} ]; then
        ${offOutput}
        awake=0
      fi
      sleep 1
    done
  '';

  dashboardArg = lib.escapeShellArg dashboardUrl;
  dashboardUrlXml = builtins.replaceStrings [ "&" ] [ "&amp;" ] dashboardUrl;

  autostart = pkgs.writeShellScript "labwc-autostart" ''
    ${applyOutput}
    ${pkgs.wbg}/bin/wbg --color 1d2021 &
    ${presenceWatch} &
    deadline=$((SECONDS + 150))
    while [ "$SECONDS" -lt "$deadline" ]; do
      ${pkgs.curl}/bin/curl -sf -o /dev/null --max-time 4 ${dashboardArg} && break
      sleep 3
    done
    ${browser} --ozone-platform=wayland --noerrdialogs --disable-infobars --disable-session-crashed-bubble --disable-background-timer-throttling --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --hide-scrollbars --kiosk ${dashboardArg} &
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
    export XCURSOR_THEME=transparent
    export XCURSOR_SIZE=24
    exec ${compositor}/bin/labwc -C ${labwcConfigDir}/labwc
  '';
in
{
  options.services.kioskConsole.enable = lib.mkEnableOption "kiosk Wayland console on the bar display";

  config = lib.mkIf cfg.enable {
    programs.labwc.enable = true;

    security.polkit.enable = true;

    users.users.${kioskUser} = {
      isNormalUser = true;
      home = "/home/${kioskUser}";
      extraGroups = [ "gpio" ];
    };

    users.groups.gpio = { };

    services = {
      dbus.enable = true;

      udev.extraRules = ''
        SUBSYSTEM=="gpio", KERNEL=="gpiochip[0-9]*", GROUP="gpio", MODE="0660"
      '';

      greetd = {
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
    };

    environment = {
      etc = {
        "labwc/labwc/autostart".source = autostart;
        "labwc/labwc/rc.xml".source = rcXml;
        "labwc/labwc/menu.xml".source = menuXml;
      };
      systemPackages = [
        compositor
        transparentCursor
        pkgs.foot
        pkgs.fuzzel
        pkgs.chromium
        pkgs.wbg
        pkgs.wlr-randr
        pkgs.libgpiod
        pkgs.libdrm
        pkgs.edid-decode
      ];
    };
  };
}
