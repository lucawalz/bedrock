# Domain Configuration for syslabs.dev

Quick reference for configuring your `syslabs.dev` domain.

## Current Configuration

The cluster is configured to use `syslabs.dev` with the following subdomains:

- `traefik.syslabs.dev` - Traefik dashboard
- `grafana.syslabs.dev` - Grafana monitoring

## Required Actions

### 1. Update Cert-Manager Email (Already Configured)

The Let's Encrypt cluster issuers are already configured with `luca@syslabs.dev`.

If you need to change it, edit:
- `kubernetes/clusters/home/infrastructure/networking/cert-manager/cluster-issuers/letsencrypt-prod.yaml`
- `kubernetes/clusters/home/infrastructure/networking/cert-manager/cluster-issuers/letsencrypt-staging.yaml`

Then commit and push - Flux will update automatically.

### 2. Configure DNS

You have two options:

**Option A: Manual DNS Records**
```
traefik.syslabs.dev    A    YOUR_PUBLIC_IP
grafana.syslabs.dev    A    YOUR_PUBLIC_IP
```

Or wildcard:
```
*.syslabs.dev          A    YOUR_PUBLIC_IP
```

**Option B: External-DNS (Automated)**

Set up external-dns to automatically create DNS records. See [DNS Setup Guide](dns-setup.md).

### 3. Port Forwarding

Traefik is configured with NodePort, so forward these ports from your router to any cluster node:
- Port 80 → Node IP:30080 (HTTP)
- Port 443 → Node IP:30443 (HTTPS)

Or access directly via NodePort:
- `http://NODE_IP:30080`
- `https://NODE_IP:30443`

### 4. Test DNS

After DNS propagation (can take a few minutes to hours):

```bash
# Check DNS resolution
nslookup traefik.syslabs.dev
dig traefik.syslabs.dev

# Test HTTPS (after cert-manager issues certificate)
curl -I https://traefik.syslabs.dev
```

## Adding New Services

When adding new services, update their ingress to use `syslabs.dev`:

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
        - my-service.syslabs.dev
      secretName: my-service-tls
  rules:
    - host: my-service.syslabs.dev
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

Then create the DNS record (manual or via external-dns):
```
my-service.syslabs.dev    A    YOUR_PUBLIC_IP
```

## Troubleshooting

### Certificate Issues

Check cert-manager:
```bash
kubectl get certificates -A
kubectl describe certificate <cert-name> -n <namespace>
kubectl logs -n cert-manager -l app=cert-manager
```

### DNS Issues

- Verify DNS records are created
- Check DNS propagation: `dig traefik.syslabs.dev @8.8.8.8`
- Ensure ports 80/443 are accessible from internet

### Access Issues

- Check Traefik is running: `kubectl get pods -n traefik`
- Verify ingress: `kubectl get ingress -A`
- Check service endpoints: `kubectl get endpoints -A`

## Security Notes

- All services use HTTPS with Let's Encrypt certificates
- Consider using Cloudflare for additional DDoS protection
- Use strong passwords for services exposed to the internet
- Monitor access logs regularly

