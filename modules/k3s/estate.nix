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

  systemd.services.k3s = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
  };

  services.k3s.extraFlags = [
    "--kubelet-arg=image-gc-high-threshold=70"
    "--kubelet-arg=image-gc-low-threshold=55"
    # k3s ships only imagefs and nodefs thresholds, so without this memory pressure OOM kills rather than evicting
    "--kubelet-arg=eviction-hard=memory.available<500Mi,nodefs.available<5%,imagefs.available<5%"
    "--protect-kernel-defaults=true"
  ];
}
