{
  pkgs,
  lib,
  config,
  secretsDir ? ../../secrets,
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

  output = "HDMI-A-1";
  mode = "1280x400";
  transform = "normal";

  browser = lib.getExe pkgs.chromium;

  labwcConfigDir = "/etc/labwc";

  wlrRandr = "${pkgs.wlr-randr}/bin/wlr-randr";

  dashboardUrlFile = config.age.secrets.grafana-kiosk-url.path;

  panelWidth = 1280;
  panelHeight = 400;
  grafanaHeaderHeight = 68;
  frameHeight = 600;

  probeIntervalSeconds = 30;
  probeTimeoutSeconds = 10;
  failuresBeforeAlarm = 3;

  pageFile = "$XDG_RUNTIME_DIR/wall.html";
  stateFile = "$XDG_RUNTIME_DIR/kiosk-state";
  failureFile = "$XDG_RUNTIME_DIR/kiosk-failures";
  lastContactFile = "$XDG_RUNTIME_DIR/kiosk-last-contact";

  renderPage = pkgs.writeShellScript "kiosk-render-page" ''
    umask 077
    if [ "$1" = reachable ]; then
      {
        printf '<!doctype html><meta charset="utf-8"><style>'
        printf 'html,body{margin:0;padding:0;width:%dpx;height:%dpx;overflow:hidden;background:#111217}' \
          ${toString panelWidth} ${toString panelHeight}
        printf 'iframe{position:absolute;top:-%dpx;left:0;width:%dpx;height:%dpx;border:0}' \
          ${toString grafanaHeaderHeight} ${toString panelWidth} ${toString frameHeight}
        printf '</style><iframe src="%s"></iframe>' "$(cat ${dashboardUrlFile})"
      } > ${pageFile}
    else
      last="$(cat ${lastContactFile} 2>/dev/null || echo 'not since boot')"
      {
        printf '<!doctype html><meta charset="utf-8"><style>'
        printf 'html,body{margin:0;padding:0;width:%dpx;height:%dpx;overflow:hidden;background:#140d0e;' \
          ${toString panelWidth} ${toString panelHeight}
        printf 'font-family:system-ui,sans-serif;color:#e6d9d9}'
        printf '.b{position:absolute;left:0;top:0;bottom:0;width:14px;background:#b4453f}'
        printf '.c{position:absolute;left:74px;top:0;bottom:0;right:48px;display:flex;'
        printf 'flex-direction:column;justify-content:center;gap:14px}'
        printf 'h1{margin:0;font-size:54px;font-weight:600;letter-spacing:-.02em;color:#d9615a}'
        printf 'p{margin:0;font-size:19px;color:#9a8f8f}'
        printf '</style><div class="b"></div><div class="c">'
        printf '<h1>Estate unreachable</h1>'
        printf '<p>The dashboard has not answered for %d consecutive probes.</p>'  \
          ${toString failuresBeforeAlarm}
        printf '<p>Last contact: %s</p></div>' "$last"
      } > ${pageFile}
    fi
  '';

  wallWatchdog = pkgs.writeShellScript "kiosk-watchdog" ''
    current="$(cat ${stateFile} 2>/dev/null || echo reachable)"
    if ${pkgs.curl}/bin/curl -sS -o /dev/null --max-time ${toString probeTimeoutSeconds} \
      "$(cat ${dashboardUrlFile})"; then
      ${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S %Z' > ${lastContactFile}
      echo 0 > ${failureFile}
      next=reachable
    else
      failures=$(( $(cat ${failureFile} 2>/dev/null || echo 0) + 1 ))
      echo "$failures" > ${failureFile}
      if [ "$failures" -ge ${toString failuresBeforeAlarm} ]; then next=unreachable; else next="$current"; fi
    fi
    if [ "$next" != "$current" ]; then
      echo "$next" > ${stateFile}
      ${renderPage} "$next"
      ${pkgs.systemd}/bin/systemctl --user restart kiosk-browser.service
    fi
  '';

  launchBrowser = pkgs.writeShellScript "kiosk-browser-launch" ''
    [ -f ${pageFile} ] || ${renderPage} reachable
    exec ${browser} --ozone-platform=wayland --noerrdialogs --disable-infobars \
      --disable-session-crashed-bubble --disable-background-timer-throttling \
      --disable-backgrounding-occluded-windows --disable-renderer-backgrounding \
      --hide-scrollbars --kiosk "file://${pageFile}"
  '';

  panelOn = pkgs.writeShellScript "kiosk-panel-on" ''
    ${wlrRandr} --output ${output} --on --mode ${mode} --transform ${transform}
  '';

  autostart = pkgs.writeShellScript "labwc-autostart" ''
    ${pkgs.systemd}/bin/systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE
    ${pkgs.systemd}/bin/systemctl --user start kiosk-browser.service kiosk-panel.service kiosk-watchdog.timer
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
          <action name="Execute" command="${launchBrowser}" />
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
    age.secrets.grafana-kiosk-url = {
      file = "${secretsDir}/grafana-kiosk-url.age";
      mode = "0400";
      owner = kioskUser;
      group = "users";
    };

    programs.labwc.enable = true;

    security.polkit.enable = true;

    users.users.${kioskUser} = {
      isNormalUser = true;
      home = "/home/${kioskUser}";
    };

    systemd.user.services = {
      kiosk-browser = {
        description = "Bar panel dashboard browser";
        serviceConfig = {
          ExecStart = launchBrowser;
          Restart = "always";
          RestartSec = 10;
        };
      };

      kiosk-panel = {
        description = "Bar panel power on";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = panelOn;
        };
      };

      kiosk-watchdog = {
        description = "Bar panel estate reachability probe";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = wallWatchdog;
        };
      };
    };

    systemd.user.timers.kiosk-watchdog = {
      description = "Probe the estate for the bar panel";
      timerConfig = {
        OnStartupSec = "1min";
        OnUnitActiveSec = "${toString probeIntervalSeconds}s";
        AccuracySec = "5s";
      };
    };

    services = {
      dbus.enable = true;

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
        pkgs.wlr-randr
        pkgs.libdrm
        pkgs.edid-decode
      ];
    };
  };
}
