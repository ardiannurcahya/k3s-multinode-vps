# WireGuard Full-Mesh Network

Use this design when provider private networks are unavailable or not mutually routable. Public IPs remain transport and SSH recovery endpoints. K3s node traffic uses encrypted WireGuard addresses.

## Safety Invariants

```text
Do not change the default route.
Do not use AllowedIPs = 0.0.0.0/0.
Do not add NAT, kill-switch, or policy-routing rules.
Keep public SSH available during migration.
Use exact WireGuard peer /32 routes.
Back up the control-plane before changing K3s.
Migrate workers one at a time.
```

## Reference Network

```text
WireGuard CIDR: 10.77.0.0/24
Interface:      wg0
UDP port:       51820
MTU:            1380
Keepalive:      25 seconds
Topology:       full mesh
```

Confirm this CIDR does not overlap pod, service, provider, workstation, or existing VPN networks.

## Provider Firewall

Before deployment, allow UDP `51820` to every node from exact public `/32` addresses of all other nodes. Keep existing SSH and K3s rules during migration.

After at least 24 hours of stable operation, public cluster rules can be removed:

```text
TCP 6443
TCP 10250
UDP 8472
```

Keep:

```text
UDP 51820 from cluster node public IPs
TCP 22 from trusted administrator sources
TCP 80/443 when public ingress is required
```

## Install Tools And Generate Keys

Debian/Ubuntu:

```bash
apt-get update
apt-get install -y wireguard-tools
```

AlmaLinux:

```bash
dnf --disablerepo=epel install -y wireguard-tools
```

Generate each private key on its own node:

```bash
install -d -m 700 /etc/wireguard
umask 077
wg genkey >/etc/wireguard/private.key
wg pubkey </etc/wireguard/private.key >/etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key
chmod 644 /etc/wireguard/public.key
```

Never copy private keys into inventory or Git. Collect public keys only.

## Node Configuration

Example `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.77.0.1/24
ListenPort = 51820
PrivateKey = NODE_PRIVATE_KEY
MTU = 1380

[Peer]
PublicKey = PEER_PUBLIC_KEY
Endpoint = PEER_PUBLIC_IP:51820
AllowedIPs = 10.77.0.2/32
PersistentKeepalive = 25
```

Add one peer block for every other node. Then:

```bash
chmod 600 /etc/wireguard/wg0.conf
systemctl enable --now wg-quick@wg0
```

Verify before changing K3s:

```bash
wg show wg0
ip address show wg0
ip route show default
ping -I wg0 -c 3 PEER_WIREGUARD_IP
```

Default route must still use the original public interface.

## Migrate K3s

Control-plane target arguments:

```text
--node-ip=10.77.0.1
--node-external-ip=PUBLIC_IP
--advertise-address=10.77.0.1
--flannel-iface=wg0
--tls-san=10.77.0.1
--tls-san=PUBLIC_IP
--write-kubeconfig-mode=600
```

Worker target arguments:

```text
--server=https://10.77.0.1:6443
--node-ip=NODE_WIREGUARD_IP
--node-external-ip=PUBLIC_IP
--flannel-iface=wg0
```

Remove `--flannel-external-ip`. Use a systemd drop-in so rollback only requires removing the drop-in and restarting K3s.

Add dependency:

```ini
[Unit]
Requires=wg-quick@wg0.service
After=wg-quick@wg0.service
```

Migrate control-plane first. Verify `/readyz` through its WireGuard IP. Then cordon, restart, verify, and uncordon one worker at a time.

## AlmaLinux Netfilter

If logs contain these errors:

```text
Extension comment revision 0 not supported
RULE_APPEND failed
FLANNEL-FWD
FLANNEL-POSTRTG
```

Install matching extra kernel modules and load `xt_comment`:

```bash
kernel=$(uname -r)
dnf --disablerepo=epel install -y "kernel-modules-extra-$kernel"
modprobe xt_comment
printf 'xt_comment\n' >/etc/modules-load.d/k3s-netfilter.conf
systemctl restart k3s-agent
```

Verify no new iptables errors before continuing.

## Validation

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
kubectl get --raw=/readyz?verbose
kubectl top nodes
```

Pass conditions:

```text
All InternalIP values are WireGuard IPs.
All nodes are Ready.
All system pods are Running or Completed.
Every node has a fresh handshake with every peer.
DNS, ClusterIP, and direct cross-node pod traffic work.
Public SSH still works.
Default routes still use original public interfaces.
```

## Rollback

Do not stop WireGuard first. K3s still depends on it.

1. Restore previous K3s service arguments or remove WireGuard systemd drop-ins.
2. Restart one worker at a time and confirm old InternalIP returns.
3. Restore control-plane arguments last.
4. Verify cluster health.
5. Disable `wg-quick@wg0` only after K3s no longer references WireGuard IPs.
