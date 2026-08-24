#requires -Version 7.0
<#
.SYNOPSIS
    Builds the NON-WORKING (custom-DNS-blocked) Function App scenario end to end and
    verifies that storage name resolution fails from inside the app.

.DESCRIPTION
    1. Creates a resource group tagged SecurityControl=Ignore.
    2. Deploys main.bicep (identity-based Linux .NET-isolated 10 EP app, VNet with custom
       DNS, NSG that allows HTTPS but denies all other outbound -- no port 53).
    3. Runs an in-app DNS/storage resolution test via the Kudu command API.

    Expected result: getent exit=2 and curl http=000 -> DNS is blocked (non-working state).

.EXAMPLE
    .\nonworking.ps1
.EXAMPLE
    .\nonworking.ps1 -ResourceGroup rg-dnsrepro-11762 -ResourceSuffix 11762 -Location eastus
#>
param(
    [string]$ResourceGroup = "rg-dnsrepro-nonworking",
    [string]$Location      = "eastus",
    [string]$NamePrefix    = "dnsrepro",
    [string]$ResourceSuffix,
    [string]$Subscription  = "2fd64258-83d0-456d-8559-4461579559d5"
)

$ErrorActionPreference = 'Stop'
$templateFile = Join-Path $PSScriptRoot 'main.bicep'

if (-not $ResourceSuffix) {
    $ResourceSuffix = -join ((48..57) | Get-Random -Count 5 | ForEach-Object { [char]$_ })
}

Write-Host "== Subscription ==" -ForegroundColor Cyan
az account set --subscription $Subscription | Out-Null

Write-Host "== Create resource group $ResourceGroup ($Location) ==" -ForegroundColor Cyan
az group create -n $ResourceGroup -l $Location --tags SecurityControl=Ignore -o none

Write-Host "== Deploy main.bicep (suffix=$ResourceSuffix) ==" -ForegroundColor Cyan
$deploy = az deployment group create `
    -g $ResourceGroup `
    --template-file $templateFile `
    --parameters namePrefix=$NamePrefix resourceSuffix=$ResourceSuffix `
    --query "properties.outputs" -o json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) { throw "Deployment failed." }

$app = $deploy.functionAppName.value
$stg = $deploy.storageAccountName.value
Write-Host "Deployed app=$app storage=$stg" -ForegroundColor Green

Write-Host "== Verify DNS is blocked (in-app via Kudu) ==" -ForegroundColor Cyan
$token = az account get-access-token --resource https://management.core.windows.net/ --query accessToken -o tsv
$kudu  = "https://$app.scm.azurewebsites.net/api/command"

# Run a single, simple command in the app container. Retries until SCM/container is ready.
function Invoke-InApp([string]$cmd) {
    $body = @{ command = $cmd; dir = "/home" } | ConvertTo-Json
    for ($i = 1; $i -le 12; $i++) {
        try {
            $resp = Invoke-RestMethod -Uri $kudu -Method Post `
                -Headers @{ Authorization = "Bearer $token" } `
                -ContentType "application/json" -Body $body -TimeoutSec 130
            if ($resp.PSObject.Properties.Name -contains 'ExitCode') { return $resp }
        } catch {
            $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            Write-Host "  SCM not ready (HTTP $code), attempt $i/12..." -ForegroundColor DarkYellow
        }
        Start-Sleep -Seconds 20
    }
    throw "SCM did not become ready."
}

# Readiness probe (simple echo) before the real checks.
$null = Invoke-InApp "echo ready"

$resolv = Invoke-InApp "cat /etc/resolv.conf"
Write-Host "--- /etc/resolv.conf ---"
Write-Host $resolv.Output

$getent = Invoke-InApp "getent hosts $stg.blob.core.windows.net"
Write-Host "--- getent hosts $stg.blob.core.windows.net --> ExitCode=$($getent.ExitCode) Output=[$($getent.Output.Trim())] ---"

if ($getent.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($getent.Output)) {
    Write-Host "RESULT: NON-WORKING scenario confirmed -- custom DNS is blocked (storage unresolvable)." -ForegroundColor Green
} else {
    Write-Host "RESULT: DNS resolved -- this is NOT the blocked scenario. Check NSG/DNS config." -ForegroundColor Red
}

