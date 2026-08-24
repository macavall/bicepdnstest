param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$Name
)
$ErrorActionPreference = 'Continue'

# Naming convention applied from -Name
$RG   = "rg-$Name"
$APP  = "func-$Name"
$STG  = "st" + (($Name -replace '[^a-zA-Z0-9]', '').ToLower())
$base = "https://$APP.azurewebsites.net"

az account set --subscription $SubscriptionId 2>$null

$key = $(az functionapp keys list -g $RG -n $APP --query masterKey -o tsv 2>$null)

function Invoke-Admin($path) {
    try {
        $r = Invoke-WebRequest -Uri "$base$path" -Headers @{ "x-functions-key" = $key } -TimeoutSec 130 -UseBasicParsing
        Write-Host "HTTP $($r.StatusCode) $path"
        Write-Host $r.Content
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        Write-Host "ERR $path : HTTP $code : $($_.Exception.Message)"
    }
}

Write-Host "===== 1. Host status ====="
Invoke-Admin "/admin/host/status"

Write-Host ""
Write-Host "===== 2. Sync triggers (the customer's failing signal) ====="
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -Uri "$base/admin/host/synctriggers" -Method Post -Headers @{ "x-functions-key" = $key } -TimeoutSec 130 -UseBasicParsing
    $sw.Stop()
    Write-Host "HTTP $($r.StatusCode) synctriggers in $($sw.Elapsed.TotalSeconds)s"
    Write-Host $r.Content
} catch {
    $sw.Stop()
    $code = $null
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    Write-Host "ERR synctriggers : HTTP $code after $($sw.Elapsed.TotalSeconds)s : $($_.Exception.Message)"
}
