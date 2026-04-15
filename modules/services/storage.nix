# Storage prerequisites for Longhorn
{ config, pkgs, meta, ... }:
{
  # iSCSI target for Longhorn volume management
  services.openiscsi = {
    enable = true;
    name = "iqn.2016-04.com.open-iscsi:${meta.hostname}";
  };

  # Longhorn workaround: symlink /usr/local/bin
  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];
}
