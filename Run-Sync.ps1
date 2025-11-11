$ErrorActionPreference = 'Stop'
$LogDir = 'E:\wplace-site\logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$ts = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$log = Join-Path $LogDir "Sync-$ts.log"

Start-Transcript -Path $log -Force
Write-Host "PSVersion: $($PSVersionTable.PSVersion)"
Write-Host "User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host "PWD before: $((Get-Location).Path)"
Write-Host "PATH: $env:PATH"

# If tools are missing in PATH when run by Task Scheduler, add them here:
# $env:Path += ';C:\Program Files\7-Zip;C:\Program Files\Git\bin;C:\Python312;C:\Python312\Scripts'

Set-Location 'E:\wplace-site'
& 'E:\wplace-site\Sync-Tiles-Optimized.ps1'
$code = if ($LASTEXITCODE) { $LASTEXITCODE } else { 0 }
Write-Host "Exit code: $code"
Stop-Transcript | Out-Null
exit $code
