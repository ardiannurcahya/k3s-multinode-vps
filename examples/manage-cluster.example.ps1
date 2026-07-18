param(
  [string] $Kubeconfig = (Join-Path (Split-Path $PSScriptRoot -Parent) 'kubeconfig.local.yaml'),
  [string] $SshKey = 'C:\Users\you\.ssh\control-plane.pem',
  [string] $SshTarget = 'root@203.0.113.10',
  [int] $LocalPort = 16443
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Kubeconfig)) { throw "Kubeconfig not found: $Kubeconfig" }
if (-not (Test-Path -LiteralPath $SshKey)) { throw "SSH key not found: $SshKey" }
if ($SshTarget -match '@(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)') { throw 'Replace TEST-NET SSH target' }

$listener = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue
if ($listener) { throw "Local port $LocalPort is occupied. Stop or verify existing process before continuing." }

$arguments = "-N -L 127.0.0.1:${LocalPort}:127.0.0.1:6443 -i `"$SshKey`" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 $SshTarget"
$sshProcess = Start-Process -FilePath 'ssh.exe' -WindowStyle Hidden -ArgumentList $arguments -PassThru

$ready = $false
foreach ($attempt in 1..10) {
  Start-Sleep -Seconds 1
  if ($sshProcess.HasExited) { break }
  if (Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue) {
    $ready = $true
    break
  }
}
if (-not $ready) { throw 'SSH tunnel failed to start' }

$env:KUBECONFIG = (Resolve-Path -LiteralPath $Kubeconfig).Path
kubectl get nodes
if ($LASTEXITCODE -ne 0) { throw "kubectl failed with exit code $LASTEXITCODE" }

Write-Output "Tunnel process ID: $($sshProcess.Id). Stop with: Stop-Process -Id $($sshProcess.Id)"
