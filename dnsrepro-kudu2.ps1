$ErrorActionPreference = 'Continue'
$RG   = "rg-dnsrepro-11762"
$APP  = "func-dnsrepro-11762"
$STG  = "stdnsrepro11762"

$token = az account get-access-token --resource https://management.core.windows.net/ --query accessToken -o tsv 2>$null
$kudu  = "https://$APP.scm.azurewebsites.net/api/command"

function Run-InApp($cmd) {
    $body = @{ command = $cmd; dir = "/home" } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod -Uri $kudu -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" -Body $body -TimeoutSec 130
        Write-Host "CMD : $cmd"
        Write-Host "OUT : $($r.Output)"
        Write-Host "ERR : $($r.Error)"
        Write-Host "EXIT: $($r.ExitCode)"
    } catch {
        $code = $null; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        Write-Host "CMD : $cmd -> REQUEST FAILED HTTP $code : $($_.Exception.Message)"
    }
    Write-Host "----"
}

Write-Host "tokenlen=$($token.Length)"
Write-Host "===== /etc/resolv.conf (custom DNS in effect) ====="
Run-InApp "cat /etc/resolv.conf"
Write-Host "===== Resolve storage blob FQDN ====="
Run-InApp "getent hosts $STG.blob.core.windows.net; echo rc=`$?"
Write-Host "===== curl storage blob (DNS + connect timing) ====="
Run-InApp "curl -s -o /dev/null -w 'http=%{http_code} dns=%{time_namelookup}s total=%{time_total}s' --max-time 30 https://$STG.blob.core.windows.net/; echo (rc=`$?)"
