# Local Kubectl Access

Use SSH tunnel so Kubernetes API does not need broad public exposure.

## 1. Fetch Kubeconfig

From trusted Windows workstation:

```powershell
scp -i C:\path\to\control-plane.pem root@CONTROL_PLANE_PUBLIC_IP:/etc/rancher/k3s/k3s.yaml .\kubeconfig.local.yaml
```

Protect file:

```powershell
icacls .\kubeconfig.local.yaml /inheritance:r /grant:r "${env:USERNAME}:(R,W)"
```

Kubeconfig contains cluster-admin credentials. Never commit it.

Linux:

```bash
scp -i ~/.ssh/control-plane.pem root@CONTROL_PLANE_PUBLIC_IP:/etc/rancher/k3s/k3s.yaml ./kubeconfig.local.yaml
chmod 600 ./kubeconfig.local.yaml
```

## 2. Change Endpoint

Set kubeconfig server to:

```text
https://127.0.0.1:16443
```

Do not use `0.0.0.0`. It is a server bind address, not a client destination.

## 3. Start Tunnel

```powershell
ssh -N -L 127.0.0.1:16443:127.0.0.1:6443 -i C:\path\to\control-plane.pem -o ExitOnForwardFailure=yes root@CONTROL_PLANE_PUBLIC_IP
```

Linux uses same OpenSSH command with a Linux key path:

```bash
ssh -N -L 127.0.0.1:16443:127.0.0.1:6443 -i ~/.ssh/control-plane.pem -o ExitOnForwardFailure=yes root@CONTROL_PLANE_PUBLIC_IP
```

Keep terminal open. In second terminal:

```powershell
$env:KUBECONFIG=(Resolve-Path .\kubeconfig.local.yaml)
kubectl get nodes
```

Or use:

```powershell
.\examples\manage-cluster.example.ps1
```

Linux:

```bash
SSH_KEY_PATH="$HOME/.ssh/control-plane.pem" \
SSH_TARGET="root@CONTROL_PLANE_PUBLIC_IP" \
bash ./examples/manage-cluster.example.sh kubectl get nodes
```

Linux helper keeps tunnel alive for supplied command and closes it afterward. Without command arguments, it runs `kubectl get nodes`.

## Common Errors

`localhost:8080`:

```text
KUBECONFIG is not set in current shell, or config cannot be read.
```

`0.0.0.0:6443`:

```text
Kubeconfig contains invalid client endpoint.
```

`TLS handshake timeout`:

```text
Tunnel is missing/stale, firewall drops direct API traffic, or wrong endpoint is used.
```

`x509` hostname/IP error:

```text
Tunnel endpoint is not included in certificate SAN or kubeconfig points to wrong address.
```
