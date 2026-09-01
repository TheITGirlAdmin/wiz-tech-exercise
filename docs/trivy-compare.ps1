# trivy-compare.ps1 - prove the image gate on camera.
#
# Scans the PRE-hardening image and the CURRENT deployed image with the EXACT
# flags the CI gate uses (app-deploy.yml -> "Trivy image scan (blocking)"):
#     severity: CRITICAL,HIGH   ignore-unfixed: true   exit-code: 1
#
# Run it once BEFORE the panel to confirm the counts you are about to quote,
# then again on camera.
#
#   .\docs\trivy-compare.ps1              # summary counts only
#   .\docs\trivy-compare.ps1 -ShowTable   # also print the full CVE table for the old image
#
# Requires: Docker running, and `az acr login --name <ACR_NAME>` (SETUP step 2).
#
# The registry is not baked in. Either pass it:
#     .\docs	rivy-compare.ps1 -Registry <ACR_NAME>.azurecr.io
# or set it once for the session:
#     $env:WIZ_ACR = '<ACR_NAME>.azurecr.io'

param(
    [string]$Registry = $env:WIZ_ACR,
    [string]$Repo     = 'tasky',
    [string]$OldTag   = 'v1',
    [string]$NewTag   = '0180056',
    [switch]$ShowTable
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Registry)) {
    throw "No registry. Pass -Registry <name>.azurecr.io, or set `$env:WIZ_ACR first."
}
$oldImage = "$Registry/${Repo}:$OldTag"
$newImage = "$Registry/${Repo}:$NewTag"

# Trivy runs as a container and has no ACR credentials of its own, so we pull
# the images with the logged-in docker CLI and hand Trivy the docker socket.
# Scanning the registry ref directly WILL fail with "authentication required".
$trivy = @('run', '--rm', '-v', '/var/run/docker.sock:/var/run/docker.sock', 'aquasec/trivy:latest')

function Get-Counts {
    param([string]$Image)

    Write-Host "  pulling $Image ..." -ForegroundColor DarkGray
    docker pull -q $Image 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "docker pull failed for $Image - run: az acr login --name $($Registry.Split('.')[0])"
    }

    Write-Host "  scanning (CRITICAL,HIGH, ignore-unfixed) ..." -ForegroundColor DarkGray
    $raw = docker @trivy image --severity CRITICAL,HIGH --ignore-unfixed --quiet --format json $Image 2>$null
    $vulns = ($raw | ConvertFrom-Json).Results |
             Where-Object { $_.Vulnerabilities } |
             ForEach-Object { $_.Vulnerabilities }

    [pscustomobject]@{
        Image    = $Image
        Critical = @($vulns | Where-Object Severity -eq 'CRITICAL').Count
        High     = @($vulns | Where-Object Severity -eq 'HIGH').Count
        Total    = @($vulns).Count
    }
}

Write-Host ""
Write-Host "BEFORE - the image the gate would have refused" -ForegroundColor Yellow
$before = Get-Counts $oldImage

Write-Host ""
Write-Host "AFTER - the image running in the cluster right now" -ForegroundColor Green
$after = Get-Counts $newImage

Write-Host ""
Write-Host ("=" * 78)
@($before, $after) | Format-Table Image, Critical, High, Total -AutoSize
Write-Host ("=" * 78)

# The gate's own verdict: exit-code 1 means a non-empty result fails the build.
$verdictBefore = if ($before.Total -gt 0) { "FAIL - blocked, never reaches ACR or the cluster" } else { "PASS" }
$verdictAfter  = if ($after.Total  -gt 0) { "FAIL - blocked" } else { "PASS - shipped" }

Write-Host ""
Write-Host "CI gate verdict (exit-code: 1, no continue-on-error):"
Write-Host ("  {0,-14} {1,4} fixable CRITICAL/HIGH  ->  {2}" -f $OldTag, $before.Total, $verdictBefore)
Write-Host ("  {0,-14} {1,4} fixable CRITICAL/HIGH  ->  {2}" -f $NewTag, $after.Total,  $verdictAfter)
Write-Host ""
Write-Host "Say: 'Same scanner, same flags as the pipeline. I caught this locally"
Write-Host "     rather than by pushing and waiting, so there is no red CI run to"
Write-Host "     show - but this is exactly what the gate refuses.'"
Write-Host ""

if ($ShowTable) {
    Write-Host "Full CVE table for $oldImage :" -ForegroundColor Yellow
    docker @trivy image --severity CRITICAL,HIGH --ignore-unfixed --quiet $oldImage
}
