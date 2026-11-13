_: {
  boot = {
    loader.efi.canTouchEfiVariables = true;
    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
      configurationLimit = 4;
      settings.editor = false;
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
