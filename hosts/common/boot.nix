_: {
  boot = {
    kernelParams = [ "systemd.tpm2_measured_os=1" ];
    loader.efi.canTouchEfiVariables = true;
    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
      configurationLimit = 4;
      settings.editor = false;
    };
    initrd.systemd = {
      sockets.systemd-pcrextend.wantedBy = [ "sockets.target" ];
      services."systemd-cryptsetup@cryptroot" = {
        overrideStrategy = "asDropin";
        wants = [ "systemd-pcrextend.socket" ];
        after = [ "systemd-pcrextend.socket" ];
      };
    };
  };
}
