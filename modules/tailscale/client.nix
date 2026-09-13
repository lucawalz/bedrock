{
  config,
  lib,
  ...
}:
let
  cfg = config.bedrock.tailscaleClient;
in
{
  options.bedrock.tailscaleClient = {
    enable = lib.mkEnableOption "Tailscale client joining this node to the tailnet";

    hostname = lib.mkOption {
      type = lib.types.str;
      description = "Tailscale device name for this node.";
    };

    authKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the decrypted Tailscale auth key for this node.";
    };

    tag = lib.mkOption {
      type = lib.types.enum [ "tag:cluster" ];
      description = "ACL tag advertised by this device. The auth key must be minted for the same tag, and the tailnet ACL must already grant it, so the set is closed to the tags the estate defines.";
    };

    advertiseSubnet = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "CIDR prefix this node advertises to the tailnet, or null for a node that only joins it.";
    };

    acceptRoutes = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Accept routes advertised by other tailnet nodes. A node that sits inside a prefix another node advertises must leave this false, since accepting the route to its own subnet creates a routing loop.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      useRoutingFeatures = if cfg.advertiseSubnet == null then "client" else "both";
      inherit (cfg) authKeyFile;
      extraUpFlags =
        lib.optional (cfg.advertiseSubnet != null) "--advertise-routes=${cfg.advertiseSubnet}"
        ++ [
          "--accept-dns=false"
          "--advertise-tags=${cfg.tag}"
          "--hostname=${cfg.hostname}"
        ]
        ++ lib.optional cfg.acceptRoutes "--accept-routes";
      # up flags apply only at first enrolment, so a rename needs the same flag on set
      extraSetFlags = [ "--hostname=${cfg.hostname}" ];
    };
  };
}
