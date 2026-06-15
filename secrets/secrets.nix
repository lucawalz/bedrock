# Age public keys for hosts

let
  # Host SSH public keys (ed25519)
  # These are the SSH host keys from /etc/ssh/ssh_host_ed25519_key.pub on each machine
  master = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAU9eaUVbsNWFhRKfzokIBEWY7mfAmb+ISf3kjVKHErx root@master";
  worker-1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBsCOF/GD5lCxesfVwG6DHGRQQCdAX5F4vld9yyk+3jR root@worker-1";
  worker-2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGCdX2yJ94TwBRr/lRbFax4xguXQGcHM2AhaFnV3UVCw root@worker-2";
  router = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMzOdJNsyGrrg4D2G4TQ9OpE3NB12ITZzdoWnG3gwUvK root@router";

  luca = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHoKFFTFmJR1CSAq55TwXHbUPTxSK847qZL0W6r/ZUV9 luca@macbook";
in
{
  "k3s-token.age".publicKeys = [ master worker-1 worker-2 luca ];
  "tailscale-authkey.age".publicKeys = [ router luca ];
  "adguard-admin.age".publicKeys = [ router luca ];
}

