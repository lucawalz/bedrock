# Age public keys for hosts

let
  # Host SSH public keys (ed25519)
  # These are the SSH host keys from /etc/ssh/ssh_host_ed25519_key.pub on each machine
  control-plane-1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICqxm9zCib4DwlpLDftuxjS/hVmmy7vMnQ46MKJEmA2j root@control-plane-1";
  worker-1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF7xowdEtDWgOBx/m1nuZ2NVzfPkXESvzMysGWUeaaNV root@worker-1";
  worker-2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPl3d7RdZyNj8V/nghnNJoE1IWC5VSF3sIxq9S9rFuyp root@worker-2";
  router = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHnDz824ffxsJJiJRnNuPhSZhxxt69uVLcBwuZxL+V08 root@router";

  luca-secure-enclave = "age1se1q26qpg7juhm90eccrlvahnyspaak3a22cxcwz62u060fkacnl0ejcyg3rqx";
  estate-breakglass = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMfTCbT6YlvmxEvMaTq+W4TMpOtPo+cRAnknC5T0ItWE estate-breakglass";
in
{
  "k3s-token.age".publicKeys = [
    control-plane-1
    luca-secure-enclave
    estate-breakglass
  ];
  "k3s-agent-token.age".publicKeys = [
    control-plane-1
    worker-1
    worker-2
    luca-secure-enclave
    estate-breakglass
  ];
  "k3s-ca.age".publicKeys = [
    control-plane-1
    luca-secure-enclave
    estate-breakglass
  ];
  "etcd-s3-credentials.age".publicKeys = [
    control-plane-1
    luca-secure-enclave
    estate-breakglass
  ];
  "tailscale-authkey.age".publicKeys = [
    router
    luca-secure-enclave
    estate-breakglass
  ];
  "tailscale-authkey-control-plane-1.age".publicKeys = [
    control-plane-1
    luca-secure-enclave
    estate-breakglass
  ];
  "tailscale-authkey-worker-1.age".publicKeys = [
    worker-1
    luca-secure-enclave
    estate-breakglass
  ];
  "tailscale-authkey-worker-2.age".publicKeys = [
    worker-2
    luca-secure-enclave
    estate-breakglass
  ];
  "adguard-admin.age".publicKeys = [
    router
    luca-secure-enclave
    estate-breakglass
  ];
  "grafana-kiosk-url.age".publicKeys = [
    router
    luca-secure-enclave
    estate-breakglass
  ];
}
