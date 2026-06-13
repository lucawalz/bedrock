{ config, secretsDir ? ../../secrets, ... }:
{
  age.secrets.wg-router-private = {
    file = "${secretsDir}/wg-router-private.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.100.0.1/24" ];
    listenPort = 51820;
    privateKeyFile = config.age.secrets.wg-router-private.path;
    peers = [
      {
        publicKey = "iiQ+cY4aid75PCHcMlEkgSTmkEaWKxChiJXC6A2hCnE=";
        allowedIPs = [ "10.100.0.2/32" ];
      }
    ];
  };
}
