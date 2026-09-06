{
  subnet = "10.20.0.0/24";
  gateway = "10.20.0.1";
  serviceVip = "10.20.0.50";
  dhcpPool = "10.20.0.100 - 10.20.0.200";
  controlPlane = "cp-1";
  nodes = {
    cp-1 = {
      address = "10.20.0.10";
      mac = "98:fa:9b:a0:67:b7";
      tailscale = {
        address = "100.105.211.67";
        magicDnsName = "cp-1.tail26ab10.ts.net";
      };
    };
    worker-1 = {
      address = "10.20.0.11";
      mac = "98:fa:9b:a0:63:24";
    };
    worker-2 = {
      address = "10.20.0.12";
      mac = "98:fa:9b:34:bc:10";
    };
  };
}
