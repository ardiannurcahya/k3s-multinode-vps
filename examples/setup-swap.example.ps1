param(
  [switch] $Apply,
  [string] $InventoryPath = (Join-Path $PSScriptRoot 'nodes.local.json')
)

$ErrorActionPreference = 'Stop'

if (-not $Apply) {
  throw 'Swap changes disk and /etc/fstab. Review script, then rerun with -Apply.'
}
if (-not (Test-Path -LiteralPath $InventoryPath)) {
  throw "Inventory not found: $InventoryPath"
}

$inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json
$nodes = @($inventory.controlPlane) + @($inventory.workers)

if ($nodes.Count -eq 0) { throw 'Inventory contains no nodes' }

$remoteScript = @'
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
  if [ "$swap_type" != swap ]; then
    echo '/swapfile exists but is not recognized as swap; refusing to overwrite' >&2
    exit 1
  fi
else
  if [ "$free_mb" -lt "$required_mb" ]; then
    echo "Insufficient free space: need at least ${required_mb} MB" >&2
    exit 1
  fi
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
awk '/^[[:space:]]*#/ {next} $1=="/swapfile" && $3=="swap" {found=1} END {exit !found}' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
printf 'vm.swappiness=10\n' >/etc/sysctl.d/99-swap.conf
sysctl --system >/dev/null
free -h
'@

foreach ($node in $nodes) {
  if (-not (Test-Path -LiteralPath $node.sshKeyPath)) { throw "SSH key missing for $($node.name)" }
  Write-Output "===== $($node.name) $($node.publicIp) ====="
  $remoteScript | ssh -i $node.sshKeyPath `
    -o BatchMode=yes `
    -o ConnectTimeout=10 `
    -o StrictHostKeyChecking=yes `
    "root@$($node.publicIp)" "tr -d '\015' | bash -s"
  if ($LASTEXITCODE -ne 0) { throw "Swap setup failed on $($node.name), exit code $LASTEXITCODE" }
}
