terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.61"
    }
  }
}

data "hcloud_ssh_keys" "all" {}

locals {
  operator_public_key = trimspace(var.ssh_public_key)
  existing_operator_keys = [
    for k in data.hcloud_ssh_keys.all.ssh_keys : k
    if trimspace(k.public_key) == local.operator_public_key
  ]
  operator_key_id = length(local.existing_operator_keys) > 0 ? local.existing_operator_keys[0].id : one(hcloud_ssh_key.operator[*].id)
}

resource "hcloud_ssh_key" "operator" {
  count      = length(local.existing_operator_keys) > 0 ? 0 : 1
  name       = "horizon-operator-${var.burst_id}"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "burst_node" {
  name = "horizon-burst-${var.burst_id}"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "9993"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "burst_node" {
  name         = "horizon-burst-${var.burst_id}"
  server_type  = var.server_type
  image        = "debian-12"
  location     = var.location
  ssh_keys     = [local.operator_key_id]
  firewall_ids = [hcloud_firewall.burst_node.id]
}

module "install_burst_node" {
  source = "github.com/nix-community/nixos-anywhere//terraform/all-in-one"

  nixos_system_attr      = "github:lucawalz/bedrock/${var.flake_ref}#nixosConfigurations.hetzner-burst-node.config.system.build.toplevel"
  nixos_partitioner_attr = "github:lucawalz/bedrock/${var.flake_ref}#nixosConfigurations.hetzner-burst-node.config.system.build.diskoScript"
  target_host            = hcloud_server.burst_node.ipv4_address
  instance_id            = tostring(hcloud_server.burst_node.id)
  build_on_remote        = true
  debug_logging          = true
  install_bootloader     = true
  extra_files_script     = "${path.module}/scripts/inject-secrets.sh"
  deployment_ssh_key     = file(pathexpand("~/.ssh/id_ed25519"))
  nix_options            = { "tarball-ttl" = "0" }
}
