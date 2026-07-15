# SIEM Windows agent installer (Phase 4). RUN AS ADMINISTRATOR.
#   powershell -ExecutionPolicy Bypass -File scripts\install-windows-agent.ps1
# Optional: -AggregatorAddr "siem-host:6000" (default localhost:6000, correct
# when the aggregator's docker host is this machine's WSL).
#
# Does: download Vector 0.57.0 -> C:\Program Files\Vector, deploy
# vector\agent-windows.yaml -> C:\ProgramData\vector\vector.yaml, set machine
# env vars, register + start the "vector" Windows service (LocalSystem, which
# can read the Security channel).
param(
    [string]$AggregatorAddr = "localhost:6000",
    [string]$Version = "0.57.0"
)
$ErrorActionPreference = "Stop"
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated (Administrator) PowerShell."
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$installDir = "C:\Program Files\Vector"
$configDir  = "C:\ProgramData\vector"
$exe        = Join-Path $installDir "bin\vector.exe"

if (-not (Test-Path $exe)) {
    Write-Host "[1/5] Downloading Vector $Version..."
    $zip = Join-Path $env:TEMP "vector-$Version.zip"
    Invoke-WebRequest -Uri "https://github.com/vectordotdev/vector/releases/download/v$Version/vector-$Version-x86_64-pc-windows-msvc.zip" -OutFile $zip
    New-Item -ItemType Directory -Force $installDir | Out-Null
    Expand-Archive $zip -DestinationPath $installDir -Force
    Remove-Item $zip
    # the zip may nest under a versioned folder; normalize so bin\vector.exe exists
    if (-not (Test-Path $exe)) {
        $found = Get-ChildItem $installDir -Recurse -Filter vector.exe | Select-Object -First 1
        if (-not $found) { throw "vector.exe not found after extract" }
        $srcRoot = Split-Path -Parent (Split-Path -Parent $found.FullName)
        Get-ChildItem $srcRoot | Move-Item -Destination $installDir -Force
    }
} else { Write-Host "[1/5] Vector already present." }
& $exe --version

Write-Host "[2/5] Deploying agent config..."
New-Item -ItemType Directory -Force "$configDir\data" | Out-Null
Copy-Item (Join-Path $repoRoot "vector\agent-windows.yaml") "$configDir\vector.yaml" -Force

Write-Host "[3/5] Setting machine environment variables..."
[Environment]::SetEnvironmentVariable("VECTOR_AGGREGATOR_ADDR", $AggregatorAddr, "Machine")
[Environment]::SetEnvironmentVariable("VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION", "true", "Machine")

Write-Host "[4/5] Registering the service..."
$svc = Get-Service -Name vector -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -eq "Running") { Stop-Service vector -Force }
    & $exe service uninstall | Out-Null
}
& $exe service install --name vector --display-name "Vector (SIEM agent)" --config-yaml "$configDir\vector.yaml"

Write-Host "[5/5] Starting..."
Start-Service vector
Start-Sleep 5
$svc = Get-Service vector
Write-Host "Service status: $($svc.Status)"
if ($svc.Status -ne "Running") {
    Write-Warning "Service not running - check Application event log (source: vector) and $configDir"
}
Write-Host "Done. Events land in siem.windows_events (allow ~60s)."
