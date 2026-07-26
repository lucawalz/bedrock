{
  subnet = "10.20.0.0/24";
  gateway = "10.20.0.1";
  serviceVip = "10.20.0.50";
  dhcpPool = "10.20.0.100 - 10.20.0.200";
  nodes = {
    master = "10.20.0.10";
    worker-1 = "10.20.0.11";
    worker-2 = "10.20.0.12";
  };
}
