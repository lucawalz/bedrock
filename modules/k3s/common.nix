{
  inventory,
  lib,
  secretsDir,
  ...
}:
let
  podCidr = "10.42.0.0/16";

  clusterSources = lib.concatStringsSep "," (
    [ podCidr ] ++ lib.mapAttrsToList (_: node: node.address) inventory.nodes
  );

  kubeletPort = 10250;
  flannelVxlanPort = 8472;
  memberlistPort = 7946;
  nodeExporterPort = 9100;
  metallbMetricsPort = 9120;

  clusterTcpPorts = lib.concatMapStringsSep "," toString [
    memberlistPort
    nodeExporterPort
    metallbMetricsPort
  ];

  pullThroughCache = "https://registry.syslabs.dev";

  upstreamByRegistry = {
    "docker.io" = "https://registry-1.docker.io";
    "ghcr.io" = "https://ghcr.io";
    "quay.io" = "https://quay.io";
    "registry.k8s.io" = "https://registry.k8s.io";
  };

  mirrorStanza =
    registry: upstream:
    lib.concatMapStrings (line: "${line}\n") [
      "  ${registry}:"
      "    endpoint:"
      "      - \"${pullThroughCache}\""
      "      - \"${upstream}\""
      "    rewrite:"
      "      \"^(.*)$\": \"${registry}/$1\""
    ];
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
    allowedTCPPorts = [ kubeletPort ];
    interfaces.tailscale0.allowedUDPPorts = [ flannelVxlanPort ];
    extraCommands = ''
      iptables -A nixos-fw -s ${clusterSources} -p tcp -m multiport --dports ${clusterTcpPorts} -j nixos-fw-accept
      iptables -A nixos-fw -s ${clusterSources} -p udp --dport ${toString memberlistPort} -j nixos-fw-accept
    '';
  };

  environment.etc."k3s/flannel-net-conf.json".text =
    ''{"Network":"${podCidr}","Backend":{"Type":"vxlan","MTU":1280}}'';

  # k3s folds a trailing endpoint that equals the default one into the server fallback, where rewrites are not applied.
  environment.etc."rancher/k3s/registries.yaml".text =
    "mirrors:\n" + lib.concatStrings (lib.mapAttrsToList mirrorStanza upstreamByRegistry);

  services.k3s.extraFlags = [
    "--flannel-conf=/etc/k3s/flannel-net-conf.json"
    "--flannel-iface=tailscale0"
    "--node-label=bedrock.io/storage=true"
    "--node-label=node.longhorn.io/create-default-disk=true"
  ];

  systemd.services.k3s.after = [ "tailscaled-autoconnect.service" ];
}
