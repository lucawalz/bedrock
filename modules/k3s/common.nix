{
  lib,
  secretsDir ? ../../secrets,
  ...
}:
let
  pullThroughCache = "https://registry.syslabs.dev";

  upstreamByRegistry = {
    "docker.io" = "https://registry-1.docker.io";
    "ghcr.io" = "https://ghcr.io";
    "quay.io" = "https://quay.io";
    "registry.k8s.io" = "https://registry.k8s.io";
  };

  mirrorStanza = registry: upstream: ''
    ${registry}:
      endpoint:
        - "${pullThroughCache}"
        - "${upstream}"
      rewrite:
        "^(.*)$": "${registry}/$1"
  '';

  indentBlock =
    block:
    lib.concatMapStrings (line: "  ${line}\n") (lib.splitString "\n" (lib.removeSuffix "\n" block));
in
{
  imports = [ ./estate.nix ];

  age.secrets.k3s-token = {
    file = "${secretsDir}/k3s-token.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  networking.firewall = {
    allowedTCPPorts = [
      7946
      9100
      9120
      10250
    ];
    allowedUDPPorts = [
      7946
      8472
    ];
  };

  environment.etc."k3s/flannel-net-conf.json".text =
    ''{"Network":"10.42.0.0/16","Backend":{"Type":"vxlan","MTU":1280}}'';

  # k3s folds a trailing endpoint that equals the default one into the server fallback, where rewrites are not applied.
  environment.etc."rancher/k3s/registries.yaml".text =
    "mirrors:\n" + indentBlock (lib.concatStrings (lib.mapAttrsToList mirrorStanza upstreamByRegistry));

  services.k3s.extraFlags = [
    "--flannel-conf=/etc/k3s/flannel-net-conf.json"
    "--flannel-iface=tailscale0"
    "--node-label=bedrock.io/storage=true"
    "--node-label=node.longhorn.io/create-default-disk=true"
  ];

  systemd.services.k3s.after = [ "tailscaled-autoconnect.service" ];
}
