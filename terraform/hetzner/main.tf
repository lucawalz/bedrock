terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.61"
    }
  }
}

resource "hcloud_ssh_key" "operator" {
  name       = "horizon-operator-${var.burst_id}"
  public_key = var.ssh_public_key
}

resource "hcloud_server" "burst_node" {
  name        = "horizon-burst-${var.burst_id}"
  server_type = var.server_type
  image       = "debian-12"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.operator.id]
}

module "install_burst_node" {
  source = "github.com/nix-community/nixos-anywhere//terraform/all-in-one"

  nixos_system_attr      = "github:lucawalz/nixos-homelab/${var.flake_ref}#nixosConfigurations.hetzner-burst-node.config.system.build.toplevel"
  nixos_partitioner_attr = "github:lucawalz/nixos-homelab/${var.flake_ref}#nixosConfigurations.hetzner-burst-node.config.system.build.diskoScript"
  target_host            = hcloud_server.burst_node.ipv4_address
  instance_id            = tostring(hcloud_server.burst_node.id)
  ssh_keys               = [var.ssh_public_key]
  build_on_remote        = true
  debug_logging          = true
  install_bootloader     = true
  extra_files_script     = "${path.module}/scripts/inject-secrets.sh"
  nix_options            = { "tarball-ttl" = "0" }
}
