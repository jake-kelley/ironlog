# Point the Windows vector agent at the WSL VM's current IP. RUN AS ADMINISTRATOR.
#
# Why: when the SIEM aggregator runs in docker inside WSL2, "localhost:6000"
# works from interactive sessions but NOT from Session-0 services (the WSL
# localhost relay is per-logon-session). The WSL NAT IP works system-wide but
# changes when the WSL VM restarts, so this script must re-run after reboots.
#
#   powershell -ExecutionPolicy Bypass -File scripts\fix-windows-agent-addr.ps1 -Register
#
# -Register additionally installs a SYSTEM scheduled task that re-runs this at
# every boot (which also has the side effect of starting WSL -> docker -> the
# SIEM stack automatically).
param([switch]$Register)
$ErrorActionPreference = "Stop"
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated (Administrator) PowerShell."
}

# Starting WSL also boots docker (systemd) and the restart-unless-stopped stack.
Write-Host "Resolving WSL IP (starts WSL if needed)..."
$ip = $null
foreach ($try in 1..30) {
    $raw = (wsl -d Ubuntu hostname -I) 2>$null
    if ($raw) { $ip = ($raw.Trim() -split '\s+')[0] }
    if ($ip) { break }
    Start-Sleep 5
}
if (-not $ip) { throw "Could not determine WSL IP." }
Write-Host "WSL IP: $ip - waiting for aggregator port 6000..."
foreach ($try in 1..60) {
    if (Test-NetConnection -ComputerName $ip -Port 6000 -InformationLevel Quiet -WarningAction SilentlyContinue) { break }
    Start-Sleep 5
    if ($try -eq 60) { Write-Warning "Port 6000 not answering yet; setting the address anyway." }
}

[Environment]::SetEnvironmentVariable("VECTOR_AGGREGATOR_ADDR", "${ip}:6000", "Machine")
Restart-Service vector
Start-Sleep 4
Write-Host "VECTOR_AGGREGATOR_ADDR=${ip}:6000 ; vector service: $((Get-Service vector).Status)"

if ($Register) {
    Write-Host "Registering startup task..."
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = "PT45S"
    Register-ScheduledTask -TaskName "SIEM vector agent WSL addr" -Force `
        -Action $action -Trigger $trigger -User "SYSTEM" -RunLevel Highest | Out-Null
    Write-Host "Startup task registered (runs 45s after boot as SYSTEM)."
}
