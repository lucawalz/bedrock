_: {
  boot = {
    loader.efi.canTouchEfiVariables = true;
    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
      configurationLimit = 4;
      measuredBoot = {
        enable = true;
        pcrs = [
          0
          4
          7
        ];
      };
    };
  };
}
