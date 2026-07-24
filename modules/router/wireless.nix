{
  config,
  secretsDir ? ../../secrets,
  ...
}:
{
  age.secrets.wifi-passphrase = {
    file = "${secretsDir}/wifi-passphrase.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  services.hostapd = {
    enable = true;

    radios.wlan0 = {
      band = "2g";
      channel = 6;
      countryCode = "DE";

      networks.wlan0 = {
        ssid = "bedrock";
        authentication = {
          mode = "wpa2-sha1";
          wpaPasswordFile = config.age.secrets.wifi-passphrase.path;
        };
      };
    };
  };
}
