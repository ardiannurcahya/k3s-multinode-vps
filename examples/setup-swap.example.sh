#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ ${1:-} == --apply ]] || { echo 'Swap changes disk and /etc/fstab. Review script, then rerun with --apply.' >&2; exit 1; }
inventory_path=${2:-"$script_dir/nodes.local.json"}

command -v jq >/dev/null 2>&1 || { echo 'Required command missing: jq' >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo 'Required command missing: ssh' >&2; exit 1; }
[[ -f $inventory_path ]] || { echo "Inventory not found: $inventory_path" >&2; exit 1; }

mapfile -t nodes < <(jq -er '[.controlPlane] + .workers | .[] | [.name, .publicIp, .sshKeyPath] | @tsv' "$inventory_path")
((${#nodes[@]} > 0)) || { echo 'Inventory contains no nodes' >&2; exit 1; }

validate_ipv4() {
  local value=$1 part
  [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a parts <<<"$value"
  for part in "${parts[@]}"; do ((10#$part <= 255)) || return 1; done
}

remote_script=$(cat <<'REMOTE'
set -euo pipefail
for command in awk blkid chmod df free mkswap swapon sysctl; do
  command -v "$command" >/dev/null 2>&1 || { echo "Required command missing: $command" >&2; exit 1; }
done
root_mb=$(df -Pm / | awk 'NR==2 {print $2}')
free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
if [ "$root_mb" -lt 25000 ]; then swap_gb=2; elif [ "$root_mb" -lt 40000 ]; then swap_gb=3; else swap_gb=5; fi
required_mb=$((swap_gb * 1024 + 512))
echo "ROOT_DISK_MB=$root_mb FREE_MB=$free_mb TARGET_SWAP_GB=$swap_gb"

if [ -e /swapfile ]; then
  if [ ! -f /swapfile ] || [ -L /swapfile ]; then
    echo '/swapfile exists but is not a regular non-symlink file; refusing to modify it' >&2
    exit 1
  fi
  swap_type=$(blkid -p -s TYPE -o value /swapfile 2>/dev/null || true)
  [[ $swap_type == swap ]] || { echo '/swapfile exists but is not recognized as swap; refusing to overwrite' >&2; exit 1; }
else
  ((free_mb >= required_mb)) || { echo "Insufficient free space: need at least ${required_mb} MB" >&2; exit 1; }
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${swap_gb}G" /swapfile
  else
    dd if=/dev/zero of=/swapfile bs=1M count="$((swap_gb * 1024))" status=progress
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
fi

chmod 600 /swapfile
awk 'NR > 1 {print $1}' /proc/swaps | grep -qx '/swapfile' || swapon /swapfile
awk '/^[[:space:]]*#/ {next} $1=="/swapfile" && $3=="swap" {found=1} END {exit !found}' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
printf 'vm.swappiness=10\n' >/etc/sysctl.d/99-swap.conf
sysctl --system >/dev/null
free -h
REMOTE
)

for node in "${nodes[@]}"; do
  IFS=$'\t' read -r name public_ip ssh_key <<<"$node"
  [[ $name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "Invalid node name: $name" >&2; exit 1; }
  validate_ipv4 "$public_ip" || { echo "Invalid IPv4 publicIp on $name: $public_ip" >&2; exit 1; }
  [[ -f $ssh_key ]] || { echo "SSH key not found for $name: $ssh_key" >&2; exit 1; }
  [[ ! $public_ip =~ ^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.) ]] || { echo "Replace TEST-NET publicIp on $name" >&2; exit 1; }
  echo "===== $name $public_ip ====="
  ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
    "root@$public_ip" 'bash -s' <<<"$remote_script"
done
