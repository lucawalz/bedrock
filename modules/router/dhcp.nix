{ inventory, ... }:
{
  services.kea.dhcp4 = {
    enable = true;
    settings = {
      valid-lifetime = 43200;
      renew-timer = 21600;
      rebind-timer = 37800;

      interfaces-config = {
        interfaces = [
          "vlan20"
          "vlan30"
          "wlan0"
        ];
      };

      lease-database = {
        type = "memfile";
        persist = true;
        name = "/var/lib/kea/dhcp4.leases";
      };

      subnet4 = [
        {
          id = 1;
          inherit (inventory) subnet;
          pools = [
            { pool = inventory.dhcpPool; }
          ];
          reservations = [
            {
              hw-address = "98:fa:9b:a0:67:b7";
              ip-address = inventory.nodes.master;
            }
            {
              hw-address = "98:fa:9b:a0:63:24";
              ip-address = inventory.nodes.worker-1;
            }
            {
              hw-address = "98:fa:9b:34:bc:10";
              ip-address = inventory.nodes.worker-2;
            }
          ];
          option-data = [
            {
              name = "routers";
              data = inventory.gateway;
            }
            {
              name = "domain-name-servers";
              data = inventory.gateway;
            }
          ];
        }
        {
          id = 2;
          subnet = "10.30.0.0/24";
          pools = [
            { pool = "10.30.0.100 - 10.30.0.200"; }
          ];
          option-data = [
            {
              name = "routers";
              data = "10.30.0.1";
            }
            {
              name = "domain-name-servers";
              data = "10.30.0.1";
            }
          ];
        }
        {
          id = 3;
          subnet = "10.40.0.0/24";
          pools = [
            { pool = "10.40.0.100 - 10.40.0.200"; }
          ];
          option-data = [
            {
              name = "routers";
              data = "10.40.0.1";
            }
            {
              name = "domain-name-servers";
              data = "10.40.0.1";
            }
          ];
        }
      ];
    };
  };
}
