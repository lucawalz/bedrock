# DNS Setup for syslabs.dev

This guide explains how to configure DNS for your `syslabs.dev` domain to work with your homelab.

## Prerequisites

- Domain `syslabs.dev` registered
- Public IP address (static or dynamic)
- Access to your domain's DNS provider

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

### Option 2: External-DNS (Automated)

If you want automatic DNS record management, set up external-dns:

1. **Choose a DNS provider** (Cloudflare, AWS Route53, etc.)

2. **Create a secret** with your DNS provider credentials:
   ```bash
   # Example for Cloudflare
   kubectl create secret generic cloudflare-api-token \
     --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN \
     -n networking
   ```

3. **Deploy external-dns** (add to `infrastructure/networking/external-dns/`)

4. **Configure** external-dns to watch for Ingress resources and create DNS records automatically

## Port Forwarding

If you're behind a router/NAT, forward ports to your Traefik service:

1. **Find Traefik service NodePort**:
   ```bash
   kubectl get svc -n traefik traefik
   ```

2. **Forward ports in your router**:
   - Port 80 → Traefik service (for HTTP)
   - Port 443 → Traefik service (for HTTPS)

3. **Or use Traefik's LoadBalancer** (if your cluster supports it):
   ```yaml
   # In traefik/values.yaml
   service:
     type: LoadBalancer
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

Cert-manager will automatically obtain Let's Encrypt certificates once:

1. DNS records are pointing to your IP
2. Ports 80 and 443 are accessible
3. Traefik is running and accessible

Check certificate status:

```bash
kubectl get certificates -A
kubectl describe certificate traefik-dashboard-tls -n traefik
```

## Troubleshooting

### DNS not resolving

- Check DNS records are created correctly
- Wait for DNS propagation (can take up to 48 hours, usually much faster)
- Verify nameservers are correct

### Certificates not issuing

- Check DNS resolution works from outside your network
- Verify ports 80 and 443 are accessible
- Check cert-manager logs: `kubectl logs -n cert-manager -l app=cert-manager`
- Use staging issuer first to test

### Services not accessible

- Verify Traefik is running: `kubectl get pods -n traefik`
- Check ingress configuration: `kubectl get ingress -A`
- Verify firewall rules allow ports 80/443

## Email for Let's Encrypt

Update the email in cert-manager cluster issuers:

1. Edit `infrastructure/networking/cert-manager/cluster-issuers/letsencrypt-prod.yaml`
2. Change `your-email@example.com` to your actual email
3. This email receives expiry notices and important updates

## Security Considerations

- Use strong passwords for services exposed to the internet
- Consider using Cloudflare proxy for DDoS protection
- Enable firewall rules to restrict access if needed
- Regularly update certificates and services
- Monitor access logs for suspicious activity

