packer {
  required_plugins {
    hcloud = {
      # renovate: datasource=github-releases depName=hetznercloud/packer-plugin-hcloud extractVersion=^v(?<version>.+)$
      version = "= 1.8.0"
      source  = "github.com/hetznercloud/hcloud"
    }
  }
}
