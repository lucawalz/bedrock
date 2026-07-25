packer {
  required_plugins {
    hcloud = {
      # renovate: datasource=github-releases depName=hetznercloud/packer-plugin-hcloud extractVersion=^v(?<version>.+)$
      version = "= 1.7.2"
      source  = "github.com/hetznercloud/hcloud"
    }
  }
}
