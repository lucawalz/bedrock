{ inventory, ... }:
{
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = inventory.gateway;
    port = 9100;
    enabledCollectors = [
      "systemd"
      "processes"
    ];
  };

  systemd.services.prometheus-node-exporter = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };
}
