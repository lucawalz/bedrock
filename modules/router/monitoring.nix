_:
{
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "10.20.0.1";
    port = 9100;
    enabledCollectors = [ "systemd" "processes" ];
  };
}
