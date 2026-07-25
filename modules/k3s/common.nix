# Shared K3s configuration for both server and agent nodes
{
  secretsDir ? ../../secrets,
  ...
}:
{
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

  # Critical: Systemd dependency ordering for K3s
  systemd.services.k3s = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
  };

  environment.etc."k3s/flannel-net-conf.json".text =
    ''{"Network":"10.42.0.0/16","Backend":{"Type":"vxlan","MTU":1280}}'';

  # k3s folds a trailing endpoint that equals the default one into the server fallback, where rewrites are not applied.
  environment.etc."rancher/k3s/registries.yaml".text = ''
    mirrors:
      docker.io:
        endpoint:
          - "https://registry.syslabs.dev"
          - "https://registry-1.docker.io"
        rewrite:
          "^(.*)$": "docker.io/$1"
      ghcr.io:
        endpoint:
          - "https://registry.syslabs.dev"
          - "https://ghcr.io"
        rewrite:
          "^(.*)$": "ghcr.io/$1"
      quay.io:
        endpoint:
          - "https://registry.syslabs.dev"
          - "https://quay.io"
        rewrite:
          "^(.*)$": "quay.io/$1"
      registry.k8s.io:
        endpoint:
          - "https://registry.syslabs.dev"
          - "https://registry.k8s.io"
        rewrite:
          "^(.*)$": "registry.k8s.io/$1"
  '';

  services.k3s.extraFlags = [
    "--kubelet-arg=image-gc-high-threshold=70"
    "--kubelet-arg=image-gc-low-threshold=55"
    "--flannel-conf=/etc/k3s/flannel-net-conf.json"
  ];
}
