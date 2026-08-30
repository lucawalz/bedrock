source "hcloud" "cluster-node" {
  token = var.hcloud_token
  # renovate: datasource=docker depName=debian versioning=docker
  image                = "debian-13"
  location             = "hel1"
  server_type          = "cx23"
  ssh_username         = "root"
  ssh_private_key_file = var.ssh_private_key_file

  snapshot_name = "bedrock-cluster-node-${var.nixos_hash}"
  snapshot_labels = {
    "bedrock-managed"    = "true"
    "bedrock-role"       = "cluster-node"
    "bedrock-nixos-hash" = var.nixos_hash
  }

  ssh_handshake_attempts = 60
  ssh_timeout            = "15m"
}

build {
  sources = ["source.hcloud.cluster-node"]

  provisioner "shell-local" {
    inline = [
      "rm -rf /tmp/packer-extra-files",
      "mkdir -p /tmp/packer-extra-files/root/.ssh",
      "chmod 700 /tmp/packer-extra-files/root/.ssh",
      "cp ${var.ssh_private_key_file}.pub /tmp/packer-extra-files/root/.ssh/authorized_keys",
      "chmod 600 /tmp/packer-extra-files/root/.ssh/authorized_keys",
      "nix run --accept-flake-config 'github:nix-community/nixos-anywhere?ref=1.13.0' -- --extra-files /tmp/packer-extra-files --ssh-option 'IdentityFile=${var.ssh_private_key_file}' --ssh-option 'StrictHostKeyChecking=no' --ssh-option 'UserKnownHostsFile=/dev/null' --flake 'github:lucawalz/bedrock/${var.nixos_commit_sha}#cluster-node' root@${build.Host}"
    ]
  }

  provisioner "shell-local" {
    inline = [
      "sleep 60",
      "until ssh -i ${var.ssh_private_key_file} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o BatchMode=yes root@${build.Host} 'cloud-init status --wait >/dev/null 2>&1 || true; sync'; do sleep 15; done"
    ]
  }

  # every clone of this snapshot boots with whatever identity the install left behind, so two registering at once resolve to one Tailscale node and the loser silently loses its route; the host keys go last because sshd needs them to accept any further connection
  provisioner "shell-local" {
    inline = [
      "ssh -i ${var.ssh_private_key_file} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes root@${build.Host} 'set -eu; : > /etc/machine-id; rm -f /var/lib/dbus/machine-id; rm -rf /var/lib/tailscale; test ! -s /etc/machine-id; test ! -e /var/lib/tailscale/tailscaled.state; echo cleared machine-id and tailscale state; rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub; sync'"
    ]
  }
}
