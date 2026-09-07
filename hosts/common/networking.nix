{
  inventory,
  meta,
  lib,
  ...
}:
let
  self = inventory.nodes.${meta.hostname};
  prefixLength = lib.last (lib.splitString "/" inventory.subnet);
in
{
  networking = {
    networkmanager = {
      enable = true;
      settings.main.no-auto-default = "*";
      ensureProfiles.profiles.static-node = {
        connection = {
          id = "static-node";
          type = "ethernet";
          autoconnect = true;
          autoconnect-priority = 10;
        };
        ethernet.mac-address = self.mac;
        ipv4 = {
          method = "manual";
          addresses = "${self.address}/${prefixLength}";
          inherit (inventory) gateway;
          dns = inventory.gateway;
        };
      };
    };
    hosts = lib.listToAttrs (
      map (name: lib.nameValuePair inventory.nodes.${name}.address [ name ]) inventory.controlPlanes
    );
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };
}
