{
  subnet = "10.20.0.0/24";
  gateway = "10.20.0.1";
  serviceVip = "10.20.0.50";
  dhcpPool = "10.20.0.100 - 10.20.0.200";
  nodes = {
    master = {
      address = "10.20.0.10";
      mac = "98:fa:9b:a0:67:b7";
      __toString = self: self.address;
    };
    worker-1 = {
      address = "10.20.0.11";
      mac = "98:fa:9b:a0:63:24";
      __toString = self: self.address;
    };
    worker-2 = {
      address = "10.20.0.12";
      mac = "98:fa:9b:34:bc:10";
      __toString = self: self.address;
    };
  };
}
