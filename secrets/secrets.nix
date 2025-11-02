# Age public keys for hosts
# 
# To get a host's SSH public key:
#   ssh-keyscan -t ed25519 home-01
# 
# Or from the machine itself:
#   cat /etc/ssh/ssh_host_ed25519_key.pub
#
# To get your personal SSH public key:
#   cat ~/.ssh/id_ed25519.pub

let
  # Host SSH public keys (ed25519)
  # These are the SSH host keys from /etc/ssh/ssh_host_ed25519_key.pub on each machine
  master = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAU9eaUVbsNWFhRKfzokIBEWY7mfAmb+ISf3kjVKHErx root@master";
  worker-1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ9ZMnrZHyY0aE72y6boCYgrUYdX9mMH3r1vWxlSZPbb root@worker-1";
  
  # Your personal SSH public key (for local editing)
  luca = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHoKFFTFmJR1CSAq55TwXHbUPTxSK847qZL0W6r/ZUV9 luca@macbook";
in
{
  "k3s-token.age".publicKeys = [ master worker-1 luca ];
  
  # Add more secrets as needed:
  # "cloudflare-tunnel.age".publicKeys = [ master worker-1 luca ];
  # "tailscale-auth.age".publicKeys = [ master worker-1 luca ];
}

