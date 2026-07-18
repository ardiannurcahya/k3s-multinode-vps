# K3s Multi-Node VPS

Reusable, sanitized guide for building a K3s cluster across small VPS instances.

Reference topology:

```text
1 control-plane
N worker nodes
Windows administration workstation
```

This repository contains public examples only. Real IP addresses, SSH keys, node tokens, firewall exports, and kubeconfig files must stay outside Git.

## Important Design Choice

Kubernetes needs more than worker-to-control-plane API connectivity. Nodes also need routable pod-network transport.

Preferred design:

```text
Node IPs: private VPC or VPN addresses reachable by every node
K3s API: private/VPN address for workers
Local kubectl: SSH tunnel to control-plane
```

If private addresses are not mutually routable, stop and create a VPN overlay such as WireGuard, Tailscale, or NetBird. Default VXLAN over public IPs is not encrypted. This repository does not enable unencrypted public VXLAN by default.

## Prerequisites

Administration workstation:

```text
Windows PowerShell 5.1 or newer
OpenSSH client
kubectl compatible with cluster version
Git
```

VPS nodes:

```text
Linux with systemd
Root SSH access using private keys
Unique node names
Stable public and cluster-network IPs
Outbound HTTPS access to GitHub and K3s downloads
Required firewall rules
Synchronized system time
```

Tested K3s version in examples:

```text
v1.36.2+k3s1
```

Change version deliberately. Do not let reruns silently upgrade nodes.

## Quick Start

1. Clone repository.
2. Copy inventory template:

```powershell
Copy-Item .\examples\nodes.example.json .\examples\nodes.local.json
```

3. Replace all example values in `examples\nodes.local.json`.
4. Verify SSH host fingerprints using provider console before first connection.
5. Add verified fingerprints to `known_hosts`.
6. Run preflight:

```powershell
.\examples\check-vps.example.ps1
```

7. Configure firewall using `examples\firewall-rules.example.csv` as conceptual schema.
8. Verify every cluster IP can reach every other cluster IP.
9. Optionally configure swap:

```powershell
.\examples\setup-swap.example.ps1 -Apply
```

10. Install K3s:

```powershell
.\examples\install-k3s-single.example.ps1 -Install
```

11. Verify from control-plane:

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
kubectl get --raw=/readyz?verbose
```

12. Manage locally through SSH tunnel. See `docs/LOCAL_ACCESS.md`.

## Firewall Summary

Cluster network, restricted to node CIDRs/IPs:

```text
TCP 6443      Kubernetes API to control-plane
TCP 10250     Kubelet between nodes
UDP 8472      Flannel VXLAN when that backend is used
TCP 22        SSH from trusted management CIDR
TCP 80/443    Optional public ingress
```

For easiest node-to-node policy, allow all protocols only between exact cluster node `/32` addresses or a dedicated private/VPN CIDR. Never expose all ports to `0.0.0.0/0`.

## Repository Layout

```text
README.md
docs/SETUP_STEPS.md
docs/LOCAL_ACCESS.md
docs/TROUBLESHOOTING.md
docs/BACKUP_RESTORE.md
docs/SECURITY.md
examples/nodes.example.json
examples/check-vps.example.ps1
examples/setup-swap.example.ps1
examples/install-k3s-single.example.ps1
examples/manage-cluster.example.ps1
examples/firewall-rules.example.csv
```

## Single Control-Plane Limitation

Single control-plane is simple but not highly available. If it fails:

```text
Existing containers may continue running.
Scheduling and cluster API stop.
Cluster management resumes only after control-plane recovery.
```

Back up datastore and server token off-host. See `docs/BACKUP_RESTORE.md`.

## Sensitive Data

Never commit:

```text
SSH private keys
K3s server token
kubeconfig files
real inventory
real firewall exports
cloud credentials
.env files
```

Before publishing:

```powershell
git status --short --ignored
git grep -n -E "BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|client-key-data:|token:"
```

`.gitignore` does not protect secrets already committed. Rotate any leaked credential and remove it from Git history.
