<#
    Wiz Technical Exercise - Azure bootstrap
    Creates the things Terraform cannot create for itself:
      1. Resource group + storage account for remote Terraform state
      2. A USER-ASSIGNED MANAGED IDENTITY with federated (OIDC) credentials
         for GitHub Actions
      3. Role assignments for that identity

    WHY A MANAGED IDENTITY AND NOT AN APP REGISTRATION
    --------------------------------------------------
    The original version of this script created an Entra ID app registration.
    The CloudLabs tenant (wiziolabs.onmicrosoft.com) denies lab users the
    directory permission to register applications:

        "Insufficient privileges to complete the operation."

    A user-assigned managed identity is an ARM *resource*, not a directory
    object, so creating it needs only subscription Owner - which the lab
    account has. Since 2023 it supports the same federated identity
    credentials that app registrations do, so GitHub Actions OIDC works
    identically. It is arguably the better control: there is no client secret
    anywhere, and the identity is deleted with its resource group.

    The previous version is kept at bootstrap-azure.entra-appreg.ps1.bak.

    Run AFTER `az login` and AFTER you have your CloudLabs subscription.
    Re-running is safe (idempotent).
#>

param(
    [Parameter(Mandatory = $true)][string]$GitHubOrg,
    [Parameter(Mandatory = $true)][string]$GitHubRepo,
    [string]$Location = 'eastus',
    [string]$Prefix = 'wizex'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Azure CLI failures are NATIVE command errors. PowerShell's
# $ErrorActionPreference does NOT catch them, which is why the previous run
# printed "Created app registration" immediately after the CLI had errored.
# Every az call goes through this wrapper so a failure is a real failure.
# ---------------------------------------------------------------------------
function Invoke-Az {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    # Do NOT redirect stderr into the output stream. Windows PowerShell wraps
    # each native stderr line in an ErrorRecord, so with $ErrorActionPreference
    # = 'Stop' an ordinary az WARNING becomes a terminating error. Let stderr go
    # straight to the console and judge success by $LASTEXITCODE alone.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & az @Arguments
    } finally {
        $ErrorActionPreference = $previous
    }

    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) {
            Write-Warning ("az {0} failed (exit {1}) - see the error above." -f ($Arguments -join ' '), $LASTEXITCODE)
            return $null
        }
        throw ("az {0} failed with exit code {1}. See the error above." -f ($Arguments -join ' '), $LASTEXITCODE)
    }
    return ($output | Out-String).Trim()
}

# --- 0. Context -------------------------------------------------------------
$sub = Invoke-Az @('account', 'show', '--query', 'id', '-o', 'tsv')
$tenant = Invoke-Az @('account', 'show', '--query', 'tenantId', '-o', 'tsv')
Write-Host "Subscription: $sub" -ForegroundColor Cyan
Write-Host "Tenant:       $tenant" -ForegroundColor Cyan

# Storage account names must be globally unique, 3-24 chars, lowercase alphanumeric
$suffix = ($sub -replace '[^0-9a-f]', '').Substring(0, 6)
$stateRg = "$Prefix-tfstate-rg"
$stateSa = "$($Prefix)tfstate$suffix"
$stateContainer = 'tfstate'
$identityName = "$Prefix-github-actions"

# --- 1. Terraform state backend --------------------------------------------
Write-Host "`n=== Creating Terraform state backend ===" -ForegroundColor Cyan
Invoke-Az @('group', 'create', '--name', $stateRg, '--location', $Location, '--output', 'none') | Out-Null

Invoke-Az @('storage', 'account', 'create',
    '--name', $stateSa, '--resource-group', $stateRg, '--location', $Location,
    '--sku', 'Standard_LRS', '--kind', 'StorageV2',
    '--min-tls-version', 'TLS1_2',
    '--allow-blob-public-access', 'false',
    '--output', 'none') | Out-Null

# Blob versioning gives you a safety net if state is ever corrupted
Invoke-Az @('storage', 'account', 'blob-service-properties', 'update',
    '--account-name', $stateSa, '--resource-group', $stateRg,
    '--enable-versioning', 'true', '--output', 'none') | Out-Null

Invoke-Az @('storage', 'container', 'create',
    '--name', $stateContainer, '--account-name', $stateSa,
    '--auth-mode', 'login', '--output', 'none') | Out-Null

Write-Host "State storage account: $stateSa" -ForegroundColor Green

# --- 2. User-assigned managed identity + OIDC federation --------------------
# Lives in the state resource group deliberately: `terraform destroy` on the
# main environment must not delete the identity the pipeline authenticates with.
Write-Host "`n=== Creating GitHub Actions identity (managed identity + OIDC) ===" -ForegroundColor Cyan

$existing = Invoke-Az @('identity', 'list', '--resource-group', $stateRg,
    '--query', "[?name=='$identityName'].name", '-o', 'tsv')

if ([string]::IsNullOrWhiteSpace($existing)) {
    Invoke-Az @('identity', 'create',
        '--name', $identityName, '--resource-group', $stateRg,
        '--location', $Location, '--output', 'none') | Out-Null
    Write-Host "Created managed identity $identityName" -ForegroundColor Green
} else {
    Write-Host "Managed identity $identityName already exists" -ForegroundColor Yellow
}

$clientId = Invoke-Az @('identity', 'show', '--name', $identityName,
    '--resource-group', $stateRg, '--query', 'clientId', '-o', 'tsv')
$principalId = Invoke-Az @('identity', 'show', '--name', $identityName,
    '--resource-group', $stateRg, '--query', 'principalId', '-o', 'tsv')

if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($principalId)) {
    throw "Managed identity was created but clientId/principalId came back empty. Stopping rather than emitting empty secrets."
}
Write-Host "clientId:    $clientId" -ForegroundColor Green
Write-Host "principalId: $principalId" -ForegroundColor Green

# Federated credentials: one per trusted GitHub context.
# 'main' covers pushes to main; 'pr' covers pull-request plan runs.
$subjects = [ordered]@{
    "$Prefix-main" = "repo:$($GitHubOrg)/$($GitHubRepo):ref:refs/heads/main"
    "$Prefix-pr"   = "repo:$($GitHubOrg)/$($GitHubRepo):pull_request"
}

foreach ($name in $subjects.Keys) {
    $have = Invoke-Az @('identity', 'federated-credential', 'list',
        '--identity-name', $identityName, '--resource-group', $stateRg,
        '--query', "[?name=='$name'].name", '-o', 'tsv')

    if (-not [string]::IsNullOrWhiteSpace($have)) {
        Write-Host "Federated credential $name already exists" -ForegroundColor Yellow
        continue
    }

    Invoke-Az @('identity', 'federated-credential', 'create',
        '--name', $name,
        '--identity-name', $identityName,
        '--resource-group', $stateRg,
        '--issuer', 'https://token.actions.githubusercontent.com',
        '--subject', $subjects[$name],
        '--audiences', 'api://AzureADTokenExchange',
        '--output', 'none') | Out-Null
    Write-Host "Created federated credential $name -> $($subjects[$name])" -ForegroundColor Green
}

# --- 3. Role assignments ----------------------------------------------------
# Contributor lets the pipeline build/destroy the environment.
# User Access Administrator is required because Terraform itself assigns roles
# (the deliberately over-permissive VM identity, and AcrPull for AKS).
#
# A freshly created identity takes a few seconds to replicate; role assignment
# against it can fail with "principal does not exist" until it does. Retry.
Write-Host "`n=== Assigning roles ===" -ForegroundColor Cyan
foreach ($role in @('Contributor', 'User Access Administrator')) {

    $already = Invoke-Az @('role', 'assignment', 'list',
        '--assignee', $principalId, '--scope', "/subscriptions/$sub",
        '--query', "[?roleDefinitionName=='$role'].roleDefinitionName", '-o', 'tsv') -AllowFailure

    if (-not [string]::IsNullOrWhiteSpace($already)) {
        Write-Host "$role already assigned" -ForegroundColor Yellow
        continue
    }

    $assigned = $false
    foreach ($attempt in 1..6) {
        $result = Invoke-Az @('role', 'assignment', 'create',
            '--assignee-object-id', $principalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', $role, '--scope', "/subscriptions/$sub",
            '--output', 'none') -AllowFailure

        if ($null -ne $result) { $assigned = $true; break }
        Write-Host "  identity not replicated yet, retrying ($attempt/6)..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }

    if ($assigned) {
        Write-Host "Assigned $role" -ForegroundColor Green
    } else {
        Write-Warning "Could not assign '$role'. If this is a restricted CloudLabs subscription, see README 'Permission fallbacks'."
    }
}

# --- 4. Output ---------------------------------------------------------------
Write-Host "`n================ GITHUB SECRETS ================" -ForegroundColor Cyan
Write-Host "Set these with the gh CLI (or Settings > Secrets and variables > Actions):`n"
Write-Host "gh secret set AZURE_CLIENT_ID       --body `"$clientId`""
Write-Host "gh secret set AZURE_TENANT_ID       --body `"$tenant`""
Write-Host "gh secret set AZURE_SUBSCRIPTION_ID --body `"$sub`""
Write-Host "gh secret set TF_STATE_RG           --body `"$stateRg`""
Write-Host "gh secret set TF_STATE_SA           --body `"$stateSa`""
Write-Host "gh secret set TF_STATE_CONTAINER    --body `"$stateContainer`""
Write-Host "gh secret set MONGO_ADMIN_PASSWORD  --body `"<choose-a-strong-password>`""
Write-Host ""
Write-Host "================ terraform/backend.conf ================" -ForegroundColor Cyan
Write-Host "resource_group_name  = `"$stateRg`""
Write-Host "storage_account_name = `"$stateSa`""
Write-Host "container_name       = `"$stateContainer`""
Write-Host "key                  = `"wiz-exercise.tfstate`""
Write-Host ""
Write-Host "Identity type: user-assigned managed identity (no client secret exists)." -ForegroundColor DarkCyan
Write-Host "Identity resource group: $stateRg  |  name: $identityName" -ForegroundColor DarkCyan
