# Security Notes

## Network

Use private VPC or encrypted VPN overlay for node traffic. Flannel VXLAN encapsulates but does not encrypt traffic.

For self-managed encrypted node transport, follow `docs/WIREGUARD.md`. Keep WireGuard `AllowedIPs` limited to exact cluster `/32` routes so public SSH and default internet routes remain unchanged.

Restrict firewall sources:

```text
Cluster ports: cluster CIDR/node IPs only
SSH: administrator VPN or fixed management CIDR
Ingress 80/443: only when intentionally public
Kubernetes API: workers plus SSH tunnel path
```

## SSH

```text
Use key-only authentication.
Verify host fingerprints before first connection.
Disable password authentication after recovery access is confirmed.
Prefer non-root operator with sudo where practical.
Keep provider console recovery available.
```

## Kubernetes Credentials

K3s admin kubeconfig is cluster-admin. Store mode `0600`, transfer only over trusted channel, and use separate least-privilege identities for daily users.

## Supply Chain

Pin K3s version. Review downloaded installer before production use. For stronger controls, mirror verified binaries and checksums internally.

## Secret Scanning

Before commit:

```powershell
git status --short --ignored
git grep -n -E "BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|client-key-data:|node-token|K3S_TOKEN"
```

Consider `gitleaks` or equivalent CI scan.
