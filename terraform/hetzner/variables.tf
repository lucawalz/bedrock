variable "burst_id" {
  description = "Unique identifier for this burst node (used in hostname and SSH key name)"
  type        = string
}

variable "server_type" {
  description = "Hetzner server type (e.g. cx22)"
  type        = string
  default     = "cx22"
}

variable "location" {
  description = "Hetzner datacenter location (fsn1, nbg1, hel1)"
  type        = string
  default     = "fsn1"
}

variable "flake_ref" {
  description = "nixos-homelab flake ref (branch or commit SHA)"
  type        = string
  default     = "main"
}

variable "ssh_public_key" {
  description = "Operator SSH public key for nixos-anywhere access"
  type        = string
  sensitive   = true
}

variable "zerotier_network_id" {
  description = "ZeroTier Central network ID injected into the burst NixOS node"
  type        = string
  sensitive   = false
}

variable "k3s_url" {
  description = "K3s server URL (https://master:6443)"
  type        = string
}

variable "k3s_token" {
  description = "K3s cluster join token"
  type        = string
  sensitive   = true
}
