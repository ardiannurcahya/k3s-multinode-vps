param(
  [string] $InventoryPath = (Join-Path $PSScriptRoot 'nodes.local.json')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InventoryPath)) {
  throw "Inventory not found. Copy nodes.example.json to nodes.local.json first: $InventoryPath"
}

$inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json
$nodes = @($inventory.controlPlane) + @($inventory.workers)

function Assert-Node {
  param($Node)

  if ($Node.name -notmatch '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') {
    throw "Invalid DNS-label node name: $($Node.name)"
  }
  foreach ($property in 'publicIp', 'clusterIp') {
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse([string]$Node.$property, [ref]$parsed)) {
      throw "Invalid $property on $($Node.name): $($Node.$property)"
    }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
      throw "Examples require IPv4 $property on $($Node.name)"
    }
    if ([string]$Node.$property -match '^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)') {
      throw "Replace TEST-NET placeholder on $($Node.name): $property"
    }
  }
  if (-not (Test-Path -LiteralPath $Node.sshKeyPath)) {
    throw "SSH key not found for $($Node.name): $($Node.sshKeyPath)"
  }
}

$remoteScript = @'
set -euo pipefail
echo "HOST=$(hostname)"
if [ -r /etc/os-release ]; then . /etc/os-release; echo "OS=$PRETTY_NAME"; fi
echo "KERNEL=$(uname -r)"
echo "CPU=$(nproc)"
awk '/MemTotal/ {printf "MEM_MB=%.0f\n", $2/1024}' /proc/meminfo
df -Pm / | awk 'NR==2 {print "DISK_ROOT_MB="$2" DISK_FREE_MB="$4" USED_PCT="$5}'
echo "ADDRESSES=$(hostname -I)"
command -v systemctl >/dev/null 2>&1 && echo SYSTEMD=YES || { echo SYSTEMD=NO; exit 1; }
[ -e /sys/fs/cgroup/cgroup.controllers ] && echo CGROUP=v2 || echo CGROUP=v1
command -v curl >/dev/null 2>&1 && echo CURL=YES || { echo CURL=NO; exit 1; }
command -v awk >/dev/null 2>&1 && echo AWK=YES || { echo AWK=NO; exit 1; }
command -v df >/dev/null 2>&1 && echo DF=YES || { echo DF=NO; exit 1; }
if command -v timedatectl >/dev/null 2>&1; then timedatectl show -p NTPSynchronized --value | sed 's/^/NTP_SYNC=/' ; fi
if command -v getenforce >/dev/null 2>&1; then getenforce | sed 's/^/SELINUX=/' ; else echo SELINUX=unavailable; fi
'@

foreach ($node in $nodes) {
  Assert-Node $node
  Write-Output "===== $($node.name) $($node.publicIp) ====="
  $remoteScript | ssh -i $node.sshKeyPath `
    -o BatchMode=yes `
    -o ConnectTimeout=10 `
    -o StrictHostKeyChecking=yes `
    "root@$($node.publicIp)" "tr -d '\015' | bash -s"
  if ($LASTEXITCODE -ne 0) {
    throw "Preflight failed on $($node.name), exit code $LASTEXITCODE"
  }
}
