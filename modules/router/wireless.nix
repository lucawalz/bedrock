{
  config,
  secretsDir,
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
        apIsolate = true;
        authentication = {
          mode = "wpa3-sae-transition";
          wpaPasswordFile = config.age.secrets.wifi-passphrase.path;
          saePasswords = [ { passwordFile = config.age.secrets.wifi-passphrase.path; } ];
        };
      };
    };
  };

  systemd.services.hostapd.restartTriggers = [ config.age.secrets.wifi-passphrase.file ];
}
