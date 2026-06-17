packer {
  required_plugins {
    hcloud = {
      version = ">= 1.5.0"
      source  = "github.com/hetznercloud/hcloud"
    }
  }
}
