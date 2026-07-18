#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
inventory_path=${1:-"$script_dir/nodes.local.json"}

command -v jq >/dev/null 2>&1 || { echo 'Required command missing: jq' >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo 'Required command missing: ssh' >&2; exit 1; }
[[ -f $inventory_path ]] || { echo "Inventory not found. Copy nodes.example.json to nodes.local.json first: $inventory_path" >&2; exit 1; }

validate_ipv4() {
  local value=$1 part
  [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a parts <<<"$value"
  for part in "${parts[@]}"; do ((10#$part <= 255)) || return 1; done
}

mapfile -t nodes < <(jq -er '[.controlPlane] + .workers | .[] | [.name, .publicIp, .clusterIp, .sshKeyPath] | @tsv' "$inventory_path")
((${#nodes[@]} > 0)) || { echo 'Inventory contains no nodes' >&2; exit 1; }

remote_script=$(cat <<'REMOTE'
set -euo pipefail
echo "HOST=$(hostname)"
if [ -r /etc/os-release ]; then . /etc/os-release; echo "OS=$PRETTY_NAME"; fi
echo "KERNEL=$(uname -r)"
echo "CPU=$(nproc)"
awk '/MemTotal/ {printf "MEM_MB=%.0f\n", $2/1024}' /proc/meminfo
df -Pm / | awk 'NR==2 {print "DISK_ROOT_MB="$2" DISK_FREE_MB="$4" USED_PCT="$5}'
echo "ADDRESSES=$(hostname -I)"
expected_cluster_ip=$1
hostname -I | tr ' ' '\n' | grep -Fxq "$expected_cluster_ip" || { echo "CLUSTER_IP_PRESENT=NO ($expected_cluster_ip)" >&2; exit 1; }
echo CLUSTER_IP_PRESENT=YES
command -v systemctl >/dev/null 2>&1 && echo SYSTEMD=YES || { echo SYSTEMD=NO; exit 1; }
[ -e /sys/fs/cgroup/cgroup.controllers ] && echo CGROUP=v2 || echo CGROUP=v1
for command in awk curl df; do
  command -v "$command" >/dev/null 2>&1 || { echo "Required command missing: $command" >&2; exit 1; }
done
if command -v timedatectl >/dev/null 2>&1; then timedatectl show -p NTPSynchronized --value | sed 's/^/NTP_SYNC=/'; fi
if command -v getenforce >/dev/null 2>&1; then getenforce | sed 's/^/SELINUX=/'; else echo SELINUX=unavailable; fi
REMOTE
)

for node in "${nodes[@]}"; do
  IFS=$'\t' read -r name public_ip cluster_ip ssh_key <<<"$node"
  [[ $name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "Invalid DNS-label node name: $name" >&2; exit 1; }
  validate_ipv4 "$public_ip" || { echo "Invalid IPv4 publicIp on $name: $public_ip" >&2; exit 1; }
  validate_ipv4 "$cluster_ip" || { echo "Invalid IPv4 clusterIp on $name: $cluster_ip" >&2; exit 1; }
  [[ ! $public_ip =~ ^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.) ]] || { echo "Replace TEST-NET publicIp on $name" >&2; exit 1; }
  [[ ! $cluster_ip =~ ^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.) ]] || { echo "Replace TEST-NET clusterIp on $name" >&2; exit 1; }
  [[ -f $ssh_key ]] || { echo "SSH key not found for $name: $ssh_key" >&2; exit 1; }

  echo "===== $name $public_ip ====="
  ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
    "root@$public_ip" "bash -s -- '$cluster_ip'" <<<"$remote_script"
done
