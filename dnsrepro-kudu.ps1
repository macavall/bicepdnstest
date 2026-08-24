$ErrorActionPreference = 'Continue'
$RG   = "rg-dnsrepro-11762"
$APP  = "func-dnsrepro-11762"
$STG  = "stdnsrepro11762"

# Kudu publishing credentials
$xml = az webapp deployment list-publishing-profiles -g $RG -n $APP --xml 2>$null
$user = ([xml]$xml).publishData.publishProfile[0].userName
$pwd  = ([xml]$xml).publishData.publishProfile[0].userPWD
$pair = "$($user):$($pwd)"
$b64  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$kudu = "https://$APP.scm.azurewebsites.net/api/command"

function Run-InApp($cmd) {
    $body = @{ command = $cmd; dir = "/home" } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod -Uri $kudu -Method Post -Headers @{ Authorization = "Basic $b64" } -ContentType "application/json" -Body $body -TimeoutSec 130
        Write-Host "CMD: $cmd"
        Write-Host "OUT: $($r.Output)"
        Write-Host "ERR: $($r.Error)"
        Write-Host "EXIT: $($r.ExitCode)"
    } catch {
        Write-Host "CMD: $cmd -> REQUEST FAILED: $($_.Exception.Message)"
    }
    Write-Host "----"
}

Write-Host "===== Resolve storage blob FQDN (through blocked custom DNS) ====="
Run-InApp "getent hosts $STG.blob.core.windows.net; echo rc=$?"

Write-Host "===== nslookup storage queue FQDN ====="
Run-InApp "nslookup $STG.queue.core.windows.net 2>&1; echo rc=$?"

Write-Host "===== Show configured resolv.conf (custom DNS) ====="
Run-InApp "cat /etc/resolv.conf 2>&1"

Write-Host "===== curl storage blob endpoint (expect DNS failure) ====="
Run-InApp "curl -s -o /dev/null -w 'http=%{http_code} dns=%{time_namelookup}s total=%{time_total}s\n' --max-time 30 https://$STG.blob.core.windows.net/ 2>&1; echo rc=$?"
