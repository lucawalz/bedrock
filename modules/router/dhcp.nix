{ ... }:
{
  services.kea.dhcp4 = {
    enable = true;
    settings = {
      valid-lifetime = 43200;
      renew-timer = 21600;
      rebind-timer = 37800;

      interfaces-config = {
        interfaces = [ "vlan20" ];
      };

      lease-database = {
        type = "memfile";
        persist = true;
        name = "/var/lib/kea/dhcp4.leases";
      };

      subnet4 = [
        {
          id = 1;
          subnet = "192.168.20.0/24";
          pools = [
            { pool = "192.168.20.100 - 192.168.20.200"; }
          ];
          reservations = [
            { hw-address = "98:fa:9b:a0:67:b7"; ip-address = "192.168.20.10"; }
            { hw-address = "98:fa:9b:a0:63:24"; ip-address = "192.168.20.11"; }
            { hw-address = "98:fa:9b:34:bc:10"; ip-address = "192.168.20.12"; }
          ];
          option-data = [
            {
              name = "routers";
              data = "192.168.20.1";
            }
            {
              name = "domain-name-servers";
              data = "192.168.20.1";
            }
          ];
        }
      ];
    };
  };
}
