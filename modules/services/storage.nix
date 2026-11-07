# Storage prerequisites for Longhorn
{ meta, pkgs, ... }:
{
  # iSCSI target for Longhorn volume management
  services.openiscsi = {
    enable = true;
    name = "iqn.2016-04.com.open-iscsi:${meta.hostname}";
  };

  # Longhorn reports KernelModulesLoaded=false without this, since nothing else pulls dm_crypt in
  boot.kernelModules = [ "dm_crypt" ];

  # Longhorn runs cryptsetup for encrypted volumes inside the host mount namespace, found through /usr/local/bin
  environment.systemPackages = [ pkgs.cryptsetup ];

  # Longhorn workaround: symlink /usr/local/bin
  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];
}
