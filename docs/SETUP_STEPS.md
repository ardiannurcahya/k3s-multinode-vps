# Setup Steps

## 1. Choose Network Model

Every node must have one cluster IP that is reachable from every other node.

Valid choices:

```text
Same VPC/private network
VPC peering with correct routes
WireGuard/Tailscale/NetBird overlay
```

Verify all-to-all TCP before installation:

```bash
nc -vz -w 3 <other-node-cluster-ip> 22
```

Verify UDP 8472 with packet capture or provider flow logs if using Flannel VXLAN. `nc` UDP success is not conclusive.

Do not continue when cluster IPs are not mutually routable. Worker registration alone does not prove cross-node pod networking works.

## 2. Create Local Inventory

Copy template:

```powershell
Copy-Item .\examples\nodes.example.json .\examples\nodes.local.json
```

Edit:

```text
k3sVersion
control-plane name/publicIp/clusterIp/sshKeyPath
worker name/publicIp/clusterIp/sshKeyPath
```

Scripts abort if RFC 5737 TEST-NET placeholder addresses remain.

## 3. Verify SSH Identity

Get SSH host-key fingerprints from provider console or trusted provisioning output. Compare before accepting first connection.

After verification, preload `known_hosts` and use strict checking:

```powershell
ssh-keyscan CONTROL_PLANE_PUBLIC_IP | Out-File -Append -Encoding ascii "$env:USERPROFILE\.ssh\known_hosts"
```

`ssh-keyscan` itself does not authenticate a key. Compare fingerprint through trusted channel first.

## 4. Run Preflight

```powershell
.\examples\check-vps.example.ps1
```

Checks include:

```text
SSH access
OS and kernel
systemd
CPU and RAM
root disk and free space
cluster IP present on host
cgroup version
time synchronization
SELinux mode
required commands
```

Fix all failures before install.

## 5. Configure Firewalls

Provider firewall/security group must be attached to every target VPS.

Recommended:

```text
Allow cluster traffic from dedicated private/VPN CIDR.
Allow SSH only from administrator CIDR or VPN.
Allow TCP 6443 only from workers and management path.
Allow public 80/443 only when ingress is needed.
```

`examples/firewall-rules.example.csv` is conceptual. Provider CSV schemas differ.

Immediate `Connection refused` suggests packets reached a host without listener, but it is not proof by itself. Verify provider firewall, host firewall, route, and listener separately.

## 6. Optional Swap

Kubernetes normally prefers no swap. Small VPS nodes may use swap when kubelet is explicitly configured with:

```text
--kubelet-arg=fail-swap-on=false
```

Apply only after reviewing target sizes:

```powershell
.\examples\setup-swap.example.ps1 -Apply
```

Sizing policy in example:

```text
<25 GB root disk -> 2 GB
25-40 GB root disk -> 3 GB
>=40 GB root disk -> 5 GB
```

Script refuses to overwrite unknown existing `/swapfile` content and checks free space.

## 7. Install Control-Plane And Workers

Review inventory and script first:

```powershell
.\examples\install-k3s-single.example.ps1 -Install
```

Installer behavior:

```text
Pins configured K3s version.
Refuses TEST-NET placeholders.
Refuses existing K3s installation.
Uses mode 0600 for admin kubeconfig.
Enables kubelet swap only when configured.
Stops on first failed node.
Does not uninstall or reset existing nodes.
```

For SELinux enforcing hosts, install supported `k3s-selinux` policy package. Example does not silently disable SELinux.

## 8. Verify Cluster

On control-plane:

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
kubectl get --raw=/readyz?verbose
```

Pass conditions:

```text
Every node is Ready.
System pods are Running or Completed.
readyz reports passed.
```

Test cross-node pod network, not only node status:

```bash
kubectl create deployment nettest --image=nginx:alpine --replicas=2
kubectl expose deployment nettest --port=80
kubectl get pods -o wide
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl -- curl -fsS http://nettest
kubectl delete deployment nettest
kubectl delete service nettest
```

Confirm replicas landed on different nodes before treating this as cross-node validation.

## 9. Configure Local Access

Follow `docs/LOCAL_ACCESS.md`. Preferred route is SSH tunnel, not public cluster-admin API exposure.

## 10. Configure Backup

Follow `docs/BACKUP_RESTORE.md` before deploying important workloads.

## Cleanup

Cleanup is destructive. Back up first.

Worker:

```bash
/usr/local/bin/k3s-agent-uninstall.sh
```

Control-plane:

```bash
/usr/local/bin/k3s-uninstall.sh
```

Uninstalling control-plane destroys cluster datastore on that node. Never run this as routine troubleshooting.
