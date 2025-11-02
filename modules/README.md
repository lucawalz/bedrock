# Custom NixOS Modules

Optional custom NixOS modules for advanced configurations.

## Structure

- `k3s-cluster/` - Custom module for K3s cluster management

## Creating a Module

A custom module is a Nix file that returns an options/configuration set:

```nix
{ config, lib, pkgs, ... }:

with lib;

{
  options = {
    # Define options here
  };

  config = {
    # Set default configuration here
  };
}
```

## Usage

Import custom modules in host configurations:

```nix
{ config, pkgs, ... }:
{
  imports = [
    ../../modules/k3s-cluster
  ];
}
```

## k3s-cluster Module

Example module that abstracts K3s server/agent configuration. See `k3s-cluster/default.nix` for implementation.

