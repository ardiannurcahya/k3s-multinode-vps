# Troubleshooting

## Node Is Not Ready

Control-plane:

```bash
kubectl describe node NODE_NAME
kubectl get events -A --sort-by=.lastTimestamp
```

Worker:

```bash
systemctl status k3s-agent --no-pager -l
journalctl -u k3s-agent -n 200 --no-pager
```

## Worker Cannot Join

From worker:

```bash
curl --cacert /var/lib/rancher/k3s/agent/server-ca.crt --connect-timeout 8 https://CONTROL_PLANE_CLUSTER_IP:6443/cacerts
```

For a node that has never joined and has no trusted CA yet, test TCP reachability separately. Do not use `curl -k` as proof of server identity.

Check:

```text
Correct token
TCP 6443 route/firewall
Clock synchronization
TLS SAN/address
Unique node name
```

## Node Ready But Pods Cannot Talk Across Nodes

Likely cluster IP or CNI transport issue.

Check:

```bash
ip route
cat /run/flannel/subnet.env
journalctl -u k3s-agent -n 200 --no-pager
```

Verify all node cluster IPs are mutually routable. Worker API registration through public address does not prove pod-network transport works.

## ServiceLB Pod Stuck ContainerCreating

Inspect:

```bash
kubectl -n kube-system get pods --show-labels
kubectl -n kube-system describe pod POD_NAME
```

If events show iptables `MARK`, `comment`, or hostPort incompatibility, opt ServiceLB into known-good nodes:

```bash
kubectl label node GOOD_NODE_1 GOOD_NODE_2 svccontroller.k3s.cattle.io/enablelb=true --overwrite
kubectl -n kube-system get pods -l svccontroller.k3s.cattle.io/svcname=traefik
kubectl -n kube-system delete pod -l svccontroller.k3s.cattle.io/svcname=traefik
```

Confirm labels used by installed K3s release before deletion.

## SELinux Installation Failure

On enforcing distributions, install K3s SELinux policy from supported repository. Do not disable SELinux only to make install pass.

Check:

```bash
getenforce
rpm -qa | grep k3s-selinux
```

## Repository Download Failure

Verify outbound DNS/HTTPS:

```bash
curl -I https://github.com
curl -I https://get.k3s.io
```

Disable broken unrelated package repositories only after understanding impact. Do not globally disable certificate verification.
