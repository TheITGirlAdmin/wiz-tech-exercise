<#
    Wiz Technical Exercise - local toolchain installer
    Run in an ELEVATED PowerShell window:  .\bootstrap\install-tools.ps1
    Docker Desktop requires a reboot after install.
#>

$ErrorActionPreference = 'Stop'

$tools = @(
    @{ Id = 'Git.Git';              Name = 'Git' },
    @{ Id = 'Microsoft.AzureCLI';   Name = 'Azure CLI' },
    @{ Id = 'Hashicorp.Terraform';  Name = 'Terraform' },
    @{ Id = 'Kubernetes.kubectl';   Name = 'kubectl' },
    @{ Id = 'GitHub.cli';           Name = 'GitHub CLI' },
    @{ Id = 'Helm.Helm';            Name = 'Helm' },
    @{ Id = 'Docker.DockerDesktop'; Name = 'Docker Desktop' }
)

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget not found. Install "App Installer" from the Microsoft Store, then re-run.'
}

foreach ($t in $tools) {
    Write-Host "`n=== Installing $($t.Name) ($($t.Id)) ===" -ForegroundColor Cyan
    winget install --id $t.Id --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Write-Warning "$($t.Name) returned exit code $LASTEXITCODE - check manually."
    }
}

Write-Host "`n=== Generating SSH keypair for the Mongo VM ===" -ForegroundColor Cyan
$sshDir = Join-Path $env:USERPROFILE '.ssh'
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
$keyPath = Join-Path $sshDir 'wiz_exercise'
if (Test-Path $keyPath) {
    Write-Host "Key already exists at $keyPath - skipping." -ForegroundColor Yellow
} else {
    ssh-keygen -t rsa -b 4096 -f $keyPath -N '""' -C 'wiz-exercise'
    Write-Host "Created $keyPath" -ForegroundColor Green
}

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host 'REBOOT now (Docker Desktop needs it), then open a NEW terminal and run:'
Write-Host '  git --version; az version; terraform version; kubectl version --client; gh --version; docker version'
Write-Host ''
Write-Host 'Your VM public key (paste into terraform/terraform.tfvars as ssh_public_key):'
if (Test-Path "$keyPath.pub") { Get-Content "$keyPath.pub" }
