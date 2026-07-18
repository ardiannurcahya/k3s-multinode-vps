#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ ${1:-} == --install ]] || { echo 'Review inventory and script, then rerun with --install.' >&2; exit 1; }
inventory_path=${2:-"$script_dir/nodes.local.json"}

for command in jq ssh; do command -v "$command" >/dev/null 2>&1 || { echo "Required command missing: $command" >&2; exit 1; }; done
[[ -f $inventory_path ]] || { echo "Inventory not found: $inventory_path" >&2; exit 1; }

version=$(jq -er '.k3sVersion' "$inventory_path")
[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || { echo "Invalid pinned K3s version: $version" >&2; exit 1; }
swap_arg=''
[[ $(jq -er '.enableSwap | type == "boolean" and . == true' "$inventory_path" 2>/dev/null || true) == true ]] && swap_arg=' --kubelet-arg=fail-swap-on=false'

mapfile -t nodes < <(jq -er '[.controlPlane] + .workers | .[] | [.name, .publicIp, .clusterIp, .sshKeyPath] | @tsv' "$inventory_path")
worker_count=$(jq -er '.workers | length' "$inventory_path")
((worker_count > 0)) || { echo 'Inventory must contain at least one worker' >&2; exit 1; }

validate_ipv4() {
  local value=$1 part
  [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a parts <<<"$value"
  for part in "${parts[@]}"; do ((10#$part <= 255)) || return 1; done
}

declare -A seen_names=() seen_public_ips=() seen_cluster_ips=()
for node in "${nodes[@]}"; do
  IFS=$'\t' read -r name public_ip cluster_ip ssh_key <<<"$node"
  [[ $name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "Invalid node name: $name" >&2; exit 1; }
  validate_ipv4 "$public_ip" || { echo "Invalid IPv4 publicIp on $name" >&2; exit 1; }
  validate_ipv4 "$cluster_ip" || { echo "Invalid IPv4 clusterIp on $name" >&2; exit 1; }
  [[ ! $public_ip =~ ^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.) ]] || { echo "Replace TEST-NET publicIp on $name" >&2; exit 1; }
  [[ ! $cluster_ip =~ ^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.) ]] || { echo "Replace TEST-NET clusterIp on $name" >&2; exit 1; }
  [[ -f $ssh_key ]] || { echo "SSH key not found for $name: $ssh_key" >&2; exit 1; }
  [[ ! ${seen_names[$name]+set} ]] || { echo "Duplicate node name: $name" >&2; exit 1; }
  [[ ! ${seen_public_ips[$public_ip]+set} ]] || { echo "Duplicate publicIp: $public_ip" >&2; exit 1; }
  [[ ! ${seen_cluster_ips[$cluster_ip]+set} ]] || { echo "Duplicate clusterIp: $cluster_ip" >&2; exit 1; }
  seen_names[$name]=1; seen_public_ips[$public_ip]=1; seen_cluster_ips[$cluster_ip]=1
done

run_remote() {
  local public_ip=$1 ssh_key=$2 script=$3
  ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=yes \
    "root@$public_ip" 'bash -s' <<<"$script"
}

for node in "${nodes[@]}"; do
  IFS=$'\t' read -r name public_ip _ ssh_key <<<"$node"
  echo "===== preflight $name $public_ip ====="
  run_remote "$public_ip" "$ssh_key" 'set -euo pipefail; if command -v k3s >/dev/null 2>&1 || systemctl list-unit-files | grep -qE "^k3s(-agent)?\.service"; then echo "Existing K3s detected; refusing install" >&2; exit 1; fi'
done

IFS=$'\t' read -r server_name server_public_ip server_cluster_ip server_key <<<"${nodes[0]}"
server_script=$(cat <<REMOTE
set -euo pipefail
tmp=\$(mktemp)
trap 'rm -f "\$tmp"' EXIT
curl -sfL https://get.k3s.io -o "\$tmp"
INSTALL_K3S_VERSION='$version' INSTALL_K3S_EXEC='server --node-name $server_name --node-ip $server_cluster_ip --advertise-address $server_cluster_ip --bind-address 0.0.0.0 --write-kubeconfig-mode 600$swap_arg' sh "\$tmp"
systemctl is-active --quiet k3s
REMOTE
)
echo "===== install $server_name $server_public_ip ====="
run_remote "$server_public_ip" "$server_key" "$server_script"

token=$(ssh -i "$server_key" -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=yes \
  "root@$server_public_ip" 'cat /var/lib/rancher/k3s/server/node-token')
[[ $token =~ ^[A-Za-z0-9:._-]+$ ]] || { echo 'Invalid or empty K3s token' >&2; exit 1; }

for ((index=1; index<${#nodes[@]}; index++)); do
  IFS=$'\t' read -r name public_ip cluster_ip ssh_key <<<"${nodes[$index]}"
  worker_script=$(cat <<REMOTE
set -euo pipefail
tmp=\$(mktemp)
trap 'rm -f "\$tmp"' EXIT
curl -sfL https://get.k3s.io -o "\$tmp"
INSTALL_K3S_VERSION='$version' K3S_URL='https://$server_cluster_ip:6443' K3S_TOKEN='$token' INSTALL_K3S_EXEC='agent --node-name $name --node-ip $cluster_ip$swap_arg' sh "\$tmp"
systemctl is-active --quiet k3s-agent
REMOTE
)
  echo "===== install $name $public_ip ====="
  run_remote "$public_ip" "$ssh_key" "$worker_script"
done
unset token

expected_nodes=${#nodes[@]}
verification_script=$(cat <<REMOTE
set -euo pipefail
for attempt in \$(seq 1 60); do
  not_ready=\$(kubectl get nodes --no-headers 2>/dev/null | awk '\$2 != "Ready" {count++} END {print count+0}')
  bad_pods=\$(kubectl -n kube-system get pods --no-headers 2>/dev/null | awk '\$3 != "Running" && \$3 != "Completed" {count++} END {print count+0}')
  node_count=\$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  if [ "\$node_count" -eq $expected_nodes ] && [ "\$not_ready" -eq 0 ] && [ "\$bad_pods" -eq 0 ] && kubectl get --raw=/readyz >/dev/null 2>&1; then
    kubectl get nodes -o wide
    kubectl -n kube-system get pods -o wide
    kubectl get --raw=/readyz?verbose
    exit 0
  fi
  sleep 5
done
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
echo 'Cluster did not become healthy within 5 minutes' >&2
exit 1
REMOTE
)
run_remote "$server_public_ip" "$server_key" "$verification_script"
