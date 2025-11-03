# DNS Setup Guide

This guide explains how to configure DNS for your domain to work with your homelab.

**For complete setup instructions, see the [Complete Setup Guide](complete-setup-guide.md).**

## Prerequisites

- Domain registered (this guide uses `syslabs.dev` as example)
- Public IP address (static or dynamic)
- Access to your domain's DNS provider
- Homelab cluster running with Traefik

## DNS Configuration Options

### Option 1: Manual DNS Records (Simplest)

Create A records for each subdomain:

```
traefik.syslabs.dev    → YOUR_PUBLIC_IP
grafana.syslabs.dev    → YOUR_PUBLIC_IP
glance.syslabs.dev     → YOUR_PUBLIC_IP
```

Or use a wildcard (if your DNS provider supports it):

```
*.syslabs.dev          → YOUR_PUBLIC_IP
```

### Option 2: Cloudflare Tunnel (Recommended for this setup)

This homelab uses Cloudflare tunnels for secure access without port forwarding:

1. **Create Cloudflare tunnel** in the Cloudflare dashboard
2. **Get tunnel token** from Cloudflare
3. **Create SOPS-encrypted secret**:
   ```bash
   # Create the secret file
   cat > kubernetes/clusters/home/infrastructure/networking/cloudflare-tunnel/secret.sops.yaml << EOF
   apiVersion: v1
   kind: Secret
   metadata:
     name: cloudflare-tunnel-secret
     namespace: cloudflare-tunnel
   type: Opaque
   data:
     tunnel-token: YOUR_TUNNEL_TOKEN_BASE64
   EOF
   
   # Encrypt with SOPS
   sops --encrypt --input-type=yaml --output-type=yaml \
     kubernetes/clusters/home/infrastructure/networking/cloudflare-tunnel/secret.sops.yaml > temp && \
     mv temp kubernetes/clusters/home/infrastructure/networking/cloudflare-tunnel/secret.sops.yaml
   ```

4. **Configure tunnel routes** in Cloudflare dashboard:
   ```
   traefik.syslabs.dev → http://traefik.traefik.svc.cluster.local:80
   grafana.syslabs.dev → http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80
   ```

5. **Deploy cloudflared** - Already configured in `infrastructure/networking/cloudflare-tunnel/`

## Access Methods

### Method 1: Cloudflare Tunnel

With Cloudflare tunnel, no port forwarding is needed:
- Traffic flows: Internet → Cloudflare → Tunnel → Your cluster
- No public IP exposure required
- Built-in DDoS protection
- Automatic SSL termination

**Check tunnel status:**
```bash
kubectl get pods -n cloudflare-tunnel
kubectl logs -n cloudflare-tunnel deployment/cloudflared
```

### Method 2: Direct Access (NodePort)

Traefik is also configured with NodePort for direct access:

**NodePort configuration:**
- HTTP: Port 30080
- HTTPS: Port 30443

**Router port forwarding (if not using tunnel):**
1. Forward external port 80 → Any cluster node IP:30080
2. Forward external port 443 → Any cluster node IP:30443

**Direct access:**
- `http://NODE_IP:30080`
- `https://NODE_IP:30443`

**Check Traefik service:**
```bash
kubectl get svc -n traefik traefik
# Should show NodePort with ports 30080 and 30443
```

## Dynamic DNS (If You Don't Have Static IP)

If your public IP changes, use a dynamic DNS service:

1. **Use a DDNS provider** (No-IP, DuckDNS, etc.)
2. **Point your domain to DDNS hostname**:
   ```
   traefik.syslabs.dev → CNAME → yourname.ddns.net
   ```

## Verifying DNS

After configuring DNS, verify it works:

```bash
# Check DNS resolution
dig traefik.syslabs.dev
nslookup traefik.syslabs.dev

# Test HTTPS
curl -I https://traefik.syslabs.dev

# Check certificate
openssl s_client -connect traefik.syslabs.dev:443 -servername traefik.syslabs.dev
```

## Certificate Management

### With Cloudflare Tunnel
Cloudflare handles SSL termination, but you can still use cert-manager for internal certificates.

### With Direct Access (NodePort)
Cert-manager will automatically obtain Let's Encrypt certificates once:

1. DNS records are pointing to your IP
2. Ports 80 and 443 are accessible
3. Traefik is running and accessible

**Check certificate status:**
```bash
kubectl get certificates -A
kubectl describe certificate traefik-dashboard-tls -n traefik
```

## Troubleshooting

### DNS not resolving

- Check DNS records are created correctly
- Wait for DNS propagation (can take up to 48 hours, usually much faster)
- Verify nameservers are correct

### Cloudflare tunnel not working

- Check tunnel status: `kubectl logs -n cloudflare-tunnel deployment/cloudflared`
- Verify tunnel token is correct in SOPS secret
- Check tunnel configuration in Cloudflare dashboard
- Ensure tunnel routes are properly configured

### Certificates not issuing

- Check DNS resolution works from outside your network
- Verify ports 80 and 443 are accessible (if using direct access)
- Check cert-manager logs: `kubectl logs -n cert-manager -l app=cert-manager`
- Use staging issuer first to test

### Services not accessible

- Verify Traefik is running: `kubectl get pods -n traefik`
- Check ingress configuration: `kubectl get ingress -A`
- If using tunnel: Check Cloudflare tunnel routes
- If using direct access: Verify firewall rules allow ports 80/443

## Using Your Own Domain

To use a different domain than `syslabs.dev`:

### 1. Update Certificate Issuer Email

Edit the cert-manager cluster issuers:
- `kubernetes/clusters/home/infrastructure/cert-manager/cluster-issuers/letsencrypt-prod.yaml`
- `kubernetes/clusters/home/infrastructure/cert-manager/cluster-issuers/letsencrypt-staging.yaml`

Change the email address to your own.

### 2. Update Ingress Resources

Find and update all ingress resources to use your domain:

```bash
# Find all ingress files
find kubernetes -name "*.yaml" -exec grep -l "syslabs.dev" {} \;

# Update each file to use your domain
# Example: change traefik.syslabs.dev to traefik.yourdomain.com
```

### 3. Create DNS Records

Create the same DNS records but for your domain:

```
traefik.yourdomain.com    A    YOUR_PUBLIC_IP
grafana.yourdomain.com    A    YOUR_PUBLIC_IP
*.yourdomain.com          A    YOUR_PUBLIC_IP  (wildcard)
```

## Managing Cloudflare Tunnel Secrets

The tunnel token is stored as a SOPS-encrypted secret. To update it:

### 1. Edit the encrypted secret
```bash
# Edit the SOPS-encrypted secret
sops kubernetes/clusters/home/infrastructure/networking/cloudflare-tunnel/secret.sops.yaml
```

### 2. Update tunnel token
Replace the `tunnel-token` value with your new token (base64 encoded):
```bash
# Encode your tunnel token
echo -n "YOUR_TUNNEL_TOKEN" | base64
```

### 3. Restart cloudflared
```bash
# Restart the deployment to pick up new token
kubectl rollout restart deployment cloudflared -n cloudflare-tunnel
```

### 4. Verify tunnel connection
```bash
# Check logs for successful connection
kubectl logs -n cloudflare-tunnel deployment/cloudflared
```

## Adding New Services

When adding new services, create ingress with your domain:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-service
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - my-service.yourdomain.com
      secretName: my-service-tls
  rules:
    - host: my-service.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 80
```

Then create the DNS record:
```
my-service.yourdomain.com    A    YOUR_PUBLIC_IP
```

## Security Considerations

- Use strong passwords for services exposed to the internet
- Consider using Cloudflare proxy for DDoS protection
- Enable firewall rules to restrict access if needed
- Regularly update certificates and services
- Monitor access logs for suspicious activity

