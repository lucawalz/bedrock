{ config, lib, ... }:
let
  cfg = config.bedrock.tailscaleSubnetRouter;
  trustedSubnet = "10.20.0.0/24";
in
{
  options.bedrock.tailscaleSubnetRouter = {
    enable = lib.mkEnableOption "Tailscale subnet router advertising the trusted LAN range";

    hostname = lib.mkOption {
      type = lib.types.str;
      description = "Tailscale device name for this subnet router.";
    };

    authKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the decrypted Tailscale auth key for this node.";
    };

    acceptRoutes = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Accept routes advertised by other tailnet nodes. A standby subnet router must leave this false, since accepting the prefix it serves creates a routing loop.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "both";
      authKeyFile = cfg.authKeyFile;
      extraUpFlags = [
        "--advertise-routes=${trustedSubnet}"
        "--accept-dns=false"
        "--advertise-tags=tag:cluster"
        "--hostname=${cfg.hostname}"
      ] ++ lib.optional cfg.acceptRoutes "--accept-routes";
    };
  };
}
