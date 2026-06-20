_:
{
  services.kea.dhcp4 = {
    enable = true;
    settings = {
      valid-lifetime = 43200;
      renew-timer = 21600;
      rebind-timer = 37800;

      interfaces-config = {
        interfaces = [ "vlan20" "vlan30" ];
      };

      lease-database = {
        type = "memfile";
        persist = true;
        name = "/var/lib/kea/dhcp4.leases";
      };

      subnet4 = [
        {
          id = 1;
          subnet = "10.20.0.0/24";
          pools = [
            { pool = "10.20.0.100 - 10.20.0.200"; }
          ];
          reservations = [
            { hw-address = "98:fa:9b:a0:67:b7"; ip-address = "10.20.0.10"; }
            { hw-address = "98:fa:9b:a0:63:24"; ip-address = "10.20.0.11"; }
            { hw-address = "98:fa:9b:34:bc:10"; ip-address = "10.20.0.12"; }
          ];
          option-data = [
            {
              name = "routers";
              data = "10.20.0.1";
            }
            {
              name = "domain-name-servers";
              data = "10.20.0.1";
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
      ];
    };
  };
}
