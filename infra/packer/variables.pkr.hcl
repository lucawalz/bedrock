variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "nixos_commit_sha" {
  type        = string
  description = "Git commit SHA pinning the flake URL used by nixos-anywhere"
}

variable "nixos_hash" {
  type        = string
  description = "Hash of the nix config tree, used as a snapshot label for cache invalidation"
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to the ED25519 private key used for both Packer SSH and nixos-anywhere"
}
