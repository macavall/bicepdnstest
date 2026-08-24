param(
    [string]$App = "func-dnsrepro-qwtcinxexyocy",
    [string]$Stg = "stdnsreproqwtcinxexyocy"
)
$ErrorActionPreference = 'Continue'
$token = az account get-access-token --resource https://management.core.windows.net/ --query accessToken -o tsv 2>$null
$kudu  = "https://$App.scm.azurewebsites.net/api/command"

function Run-InApp($cmd) {
    $body = @{ command = $cmd; dir = "/home" } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod -Uri $kudu -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" -Body $body -TimeoutSec 130
        Write-Host "OUT : $($r.Output)"
        Write-Host "EXIT: $($r.ExitCode)"
    } catch {
        $code = $null; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        Write-Host "REQUEST FAILED HTTP $code : $($_.Exception.Message)"
    }
    Write-Host "----"
}

Write-Host "===== /etc/resolv.conf ====="
Run-InApp "cat /etc/resolv.conf"
Write-Host "===== Resolve storage blob FQDN ====="
Run-InApp "getent hosts $Stg.blob.core.windows.net; echo rc=`$?"
Write-Host "===== curl storage blob ====="
Run-InApp "curl -s -o /dev/null -w 'http=%{http_code} dns=%{time_namelookup}s total=%{time_total}s' --max-time 25 https://$Stg.blob.core.windows.net/; echo \" rc=`$?\""
