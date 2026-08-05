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
    enable = lib.mkEnableOption "Tailscale client joining this node to the tailnet without advertising routes";

    hostname = lib.mkOption {
      type = lib.types.str;
      description = "Tailscale device name for this node.";
    };

    authKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the decrypted Tailscale auth key for this node.";
    };

    tag = lib.mkOption {
      type = lib.types.enum [
        "tag:cluster"
        "tag:burst"
      ];
      description = "ACL tag advertised by this device. The auth key must be minted for the same tag, and the tailnet ACL must already grant it, so the set is closed to the tags the estate defines.";
    };

    acceptRoutes = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Accept routes advertised by other tailnet nodes. A node that already sits inside an advertised prefix must leave this false, since accepting its own subnet creates a routing loop.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "client";
      inherit (cfg) authKeyFile;
      extraUpFlags = [
        "--login-server=https://controlplane.tailscale.com"
        "--accept-dns=false"
        "--advertise-tags=${cfg.tag}"
        "--hostname=${cfg.hostname}"
      ]
      ++ lib.optional cfg.acceptRoutes "--accept-routes";
    };
  };
}
