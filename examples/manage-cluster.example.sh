#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
kubeconfig=${KUBECONFIG_PATH:-"$(dirname "$script_dir")/kubeconfig.local.yaml"}
ssh_key=${SSH_KEY_PATH:-"$HOME/.ssh/control-plane.pem"}
ssh_target=${SSH_TARGET:-root@203.0.113.10}
local_port=${LOCAL_PORT:-16443}

for command in kubectl ssh ss; do command -v "$command" >/dev/null 2>&1 || { echo "Required command missing: $command" >&2; exit 1; }; done
[[ -f $kubeconfig ]] || { echo "Kubeconfig not found: $kubeconfig" >&2; exit 1; }
[[ -f $ssh_key ]] || { echo "SSH key not found: $ssh_key" >&2; exit 1; }
[[ $ssh_target =~ ^root@([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo 'SSH_TARGET must use root@IPv4 format' >&2; exit 1; }
ssh_ip=${ssh_target#root@}
IFS=. read -r -a ssh_ip_parts <<<"$ssh_ip"
for part in "${ssh_ip_parts[@]}"; do ((10#$part <= 255)) || { echo "Invalid IPv4 SSH_TARGET: $ssh_target" >&2; exit 1; }; done
[[ ! $ssh_ip =~ ^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.) ]] || { echo 'Replace TEST-NET SSH_TARGET' >&2; exit 1; }
[[ $local_port =~ ^[0-9]+$ ]] && ((10#$local_port >= 1024 && 10#$local_port <= 65535)) || { echo "Invalid LOCAL_PORT: $local_port" >&2; exit 1; }

if ss -Hln "sport = :$local_port" | grep -q .; then
  echo "Local port $local_port is occupied. Stop or verify existing process before continuing." >&2
  exit 1
fi

ssh -N -L "127.0.0.1:${local_port}:127.0.0.1:6443" -i "$ssh_key" \
  -o BatchMode=yes -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "$ssh_target" &
ssh_pid=$!
trap 'kill "$ssh_pid" 2>/dev/null || true; wait "$ssh_pid" 2>/dev/null || true' EXIT INT TERM

ready=false
for attempt in {1..10}; do
  kill -0 "$ssh_pid" 2>/dev/null || { echo 'SSH tunnel exited unexpectedly' >&2; exit 1; }
  if ss -Hln "sport = :$local_port" | grep -q .; then ready=true; break; fi
  sleep 1
done
[[ $ready == true ]] || { echo 'SSH tunnel failed to start within 10 seconds' >&2; exit 1; }

export KUBECONFIG=$kubeconfig
if (($#)); then
  "$@"
else
  kubectl get nodes
fi
