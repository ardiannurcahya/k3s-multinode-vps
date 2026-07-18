# Local Kubectl Access

Use SSH tunnel so Kubernetes API does not need broad public exposure.

## 1. Fetch Kubeconfig

From trusted workstation:

```powershell
scp -i C:\path\to\control-plane.pem root@CONTROL_PLANE_PUBLIC_IP:/etc/rancher/k3s/k3s.yaml .\kubeconfig.local.yaml
```

Protect file:

```powershell
icacls .\kubeconfig.local.yaml /inheritance:r /grant:r "${env:USERNAME}:(R,W)"
```

Kubeconfig contains cluster-admin credentials. Never commit it.

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

Keep terminal open. In second terminal:

```powershell
$env:KUBECONFIG=(Resolve-Path .\kubeconfig.local.yaml)
kubectl get nodes
```

Or use:

```powershell
.\examples\manage-cluster.example.ps1
```

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
