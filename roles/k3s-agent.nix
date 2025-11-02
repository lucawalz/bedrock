# K3s worker (agent) role

{ config, pkgs, meta, secretsDir ? ../secrets, ... }:

{
  age.secrets.k3s-token = {
    file = "${secretsDir}/k3s-token.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://master:6443";  # Adjust hostname/IP as needed
    tokenFile = config.age.secrets.k3s-token.path;
  };
}

