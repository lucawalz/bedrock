{ pkgs, ... }:
{
  services.k3s.package = pkgs.k3s_1_35;

  boot.kernel.sysctl = {
    "vm.panic_on_oom" = 0;
    "vm.overcommit_memory" = 1;
    "kernel.panic" = 10;
    "kernel.panic_on_oops" = 1;
    "kernel.keys.root_maxkeys" = 1000000;
    "kernel.keys.root_maxbytes" = 25000000;
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

  systemd.services.k3s = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
  };

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
    "--kubelet-arg=eviction-hard=memory.available<500Mi,nodefs.available<5%,imagefs.available<5%"
    "--protect-kernel-defaults=true"
  ];
}
