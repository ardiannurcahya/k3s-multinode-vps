param(
  [switch] $Install,
  [string] $InventoryPath = (Join-Path $PSScriptRoot 'nodes.local.json')
)

$ErrorActionPreference = 'Stop'

if (-not $Install) { throw 'Review inventory and script, then rerun with -Install.' }
if (-not (Test-Path -LiteralPath $InventoryPath)) { throw "Inventory not found: $InventoryPath" }

$inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json
$server = $inventory.controlPlane
$workers = @($inventory.workers)
$allNodes = @($server) + $workers
$version = [string]$inventory.k3sVersion
$swapArg = if ($inventory.enableSwap) { ' --kubelet-arg=fail-swap-on=false' } else { '' }

if ($version -notmatch '^v\d+\.\d+\.\d+\+k3s\d+$') { throw "Invalid pinned K3s version: $version" }
if ($workers.Count -eq 0) { throw 'Inventory must contain at least one worker' }

foreach ($node in $allNodes) {
  if ($node.name -notmatch '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') { throw "Invalid node name: $($node.name)" }
  foreach ($property in 'publicIp', 'clusterIp') {
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse([string]$node.$property, [ref]$parsed)) { throw "Invalid $property on $($node.name)" }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw "Examples require IPv4 $property on $($node.name)" }
    if ([string]$node.$property -match '^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)') { throw "Replace TEST-NET placeholder on $($node.name): $property" }
  }
  if (-not (Test-Path -LiteralPath $node.sshKeyPath)) { throw "SSH key missing for $($node.name)" }
}

foreach ($property in 'name', 'publicIp', 'clusterIp') {
  $duplicates = @($allNodes | Group-Object -Property $property | Where-Object Count -gt 1)
  if ($duplicates.Count -gt 0) { throw "Duplicate $property in inventory: $($duplicates.Name -join ', ')" }
}

function Invoke-NodeScript {
  param($Node, [string]$Script)

  Write-Output "===== $($Node.name) $($Node.publicIp) ====="
  $Script | ssh -i $Node.sshKeyPath `
    -o BatchMode=yes `
    -o ConnectTimeout=12 `
    -o StrictHostKeyChecking=yes `
    "root@$($Node.publicIp)" "tr -d '\015' | bash -s"
  if ($LASTEXITCODE -ne 0) { throw "Remote command failed on $($Node.name), exit code $LASTEXITCODE" }
}

foreach ($node in $allNodes) {
  Invoke-NodeScript $node 'if command -v k3s >/dev/null 2>&1 || systemctl list-unit-files | grep -qE "^k3s(-agent)?\.service"; then echo "Existing K3s detected; refusing install" >&2; exit 1; fi'
}

$serverInstall = @"
set -euo pipefail
tmp=`$(mktemp)
trap 'rm -f "`$tmp"' EXIT
curl -sfL https://get.k3s.io -o "`$tmp"
INSTALL_K3S_VERSION='$version' INSTALL_K3S_EXEC='server --node-name $($server.name) --node-ip $($server.clusterIp) --advertise-address $($server.clusterIp) --bind-address 0.0.0.0 --write-kubeconfig-mode 600$swapArg' sh "`$tmp"
systemctl is-active --quiet k3s
"@
Invoke-NodeScript $server $serverInstall

$tokenOutput = ssh -i $server.sshKeyPath `
  -o BatchMode=yes `
  -o ConnectTimeout=12 `
  -o StrictHostKeyChecking=yes `
  "root@$($server.publicIp)" 'cat /var/lib/rancher/k3s/server/node-token'
if ($LASTEXITCODE -ne 0) { throw 'Failed to read K3s node token' }
$token = "$tokenOutput".Trim()
if ([string]::IsNullOrWhiteSpace($token) -or $token -match '[\r\n]') { throw 'Invalid or empty K3s token' }

foreach ($worker in $workers) {
  $workerInstall = @"
set -euo pipefail
tmp=`$(mktemp)
trap 'rm -f "`$tmp"' EXIT
curl -sfL https://get.k3s.io -o "`$tmp"
INSTALL_K3S_VERSION='$version' K3S_URL='https://$($server.clusterIp):6443' K3S_TOKEN='$token' INSTALL_K3S_EXEC='agent --node-name $($worker.name) --node-ip $($worker.clusterIp)$swapArg' sh "`$tmp"
systemctl is-active --quiet k3s-agent
"@
  Invoke-NodeScript $worker $workerInstall
}

$verificationScript = @'
set -euo pipefail
for attempt in $(seq 1 60); do
  not_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {count++} END {print count+0}')
  bad_pods=$(kubectl -n kube-system get pods --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {count++} END {print count+0}')
  node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  if [ "$node_count" -eq EXPECTED_NODE_COUNT ] && [ "$not_ready" -eq 0 ] && [ "$bad_pods" -eq 0 ] && kubectl get --raw=/readyz >/dev/null 2>&1; then
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
'@
$verificationScript = $verificationScript.Replace('EXPECTED_NODE_COUNT', [string]$allNodes.Count)
$verificationScript | ssh -i $server.sshKeyPath `
  -o BatchMode=yes `
  -o ConnectTimeout=12 `
  -o StrictHostKeyChecking=yes `
  "root@$($server.publicIp)" "tr -d '\015' | bash -s"
if ($LASTEXITCODE -ne 0) { throw 'Final cluster verification failed' }
