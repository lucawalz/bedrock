# Host secrets

NixOS host secrets are encrypted with agenix. Each secret is encrypted to the SSH host keys of the machines that need it, so a node decrypts its own secrets at boot using its existing host key. There is no shared passphrase and nothing to distribute by hand.

`secrets.nix` lists the recipient public keys and which secret each one can open:

```nix
"k3s-token.age".publicKeys = [ master worker-1 worker-2 luca ];
"tailscale-authkey.age".publicKeys = [ router luca ];
"tailscale-authkey-worker-2.age".publicKeys = [ worker-2 luca ];
"adguard-admin.age".publicKeys = [ router luca ];
```

| Secret | Contents | Recipients | Consumer |
| --- | --- | --- | --- |
| `k3s-token.age` | K3s cluster join token | three nodes, admin | `modules/k3s/common.nix` |
| `tailscale-authkey.age` | Tailscale auth key for the primary subnet router | router, admin | `modules/router/tailscale.nix` |
| `tailscale-authkey-worker-2.age` | Tailscale auth key for the standby subnet router | worker-2, admin | `lib/default.nix` (`mkWorker`) |
| `adguard-admin.age` | bcrypt hash for the AdGuard admin login | router, admin | `modules/router/dns.nix` |

## Standby subnet router on worker-2

The router on the Pi is the primary Tailscale subnet router for `10.20.0.0/24`. worker-2 advertises the same prefix as a hot standby, so tailnet access to the lab survives a Pi outage. Tailscale fails over between two nodes advertising one prefix automatically. The standby never sets `--accept-routes`, because a subnet router that accepts the prefix it serves forms a routing loop.

worker-2 authenticates with its own auth key in `tailscale-authkey-worker-2.age`. The committed file is a placeholder until an operator populates it. To bring the standby online:

1. In the Tailscale admin console, mint a reusable auth key tagged `tag:cluster` (matching the primary), then copy the `tskey-...` value.
2. Re-encrypt the secret with the real key: `agenix -e secrets/tailscale-authkey-worker-2.age`, replacing the placeholder line with the minted key. The recipient list in `secrets.nix` already scopes it to worker-2 and the admin.
3. Apply worker-2 (`nixos-rebuild switch --flake .#worker-2 ...`); it joins the tailnet and advertises `10.20.0.0/24`.
4. In the Tailscale admin console, approve worker-2's advertised `10.20.0.0/24` route under Machines. Both the router and worker-2 must show the route approved for failover to work.

The AdGuard secret holds only the bcrypt hash of the admin password, never the password itself. The hash is injected into the AdGuard config at service start so it never lands in the world-readable Nix store. Rotating it means generating a fresh password, re-encrypting the new hash with `agenix -e secrets/adguard-admin.age`, and applying the router.

## Adding a secret or a node

1. Collect the new host's public key from `/etc/ssh/ssh_host_ed25519_key.pub`, or with `ssh-keyscan -t ed25519 <hostname>`.
2. Add it to the recipient list in `secrets.nix`.
3. Create or re-encrypt the secret with `agenix -e secrets/<name>.age`.
4. Reference it from a NixOS module with `age.secrets.<name>.file = "${secretsDir}/<name>.age"`.

Burst nodes do not use agenix. Their join token and server address are written into `/etc/horizon` during provisioning, because the machine does not exist yet when the secret is first needed.
