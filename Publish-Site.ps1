param(
  [string]$From = "E:\wplace-archive",  # source of tiles_*
  [string]$Repo = "E:\wplace-site"      # site repo
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$stamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$logDir = Join-Path $Repo "logs"
if (!(Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log    = Join-Path $logDir "publish_$stamp.log"
function Log([string]$m){ $ts=(Get-Date).ToString("s"); "$ts  $m" | Tee-Object -FilePath $log -Append | Out-Null }

Log "=== publish start ==="
Log "From=$From Repo=$Repo"

# Ensure site structure
$tilesRoot = Join-Path $Repo "tiles"
if (!(Test-Path -LiteralPath $tilesRoot)) { New-Item -ItemType Directory -Path $tilesRoot -Force | Out-Null }
$nojekyll = Join-Path $Repo ".nojekyll"
if (!(Test-Path -LiteralPath $nojekyll)) { "" | Set-Content -LiteralPath $nojekyll -Encoding Ascii }

# 1) Mirror tiles_* into Repo\tiles (incremental; no deletes)
Log "robocopy tiles_* -> $tilesRoot"
& robocopy $From $tilesRoot "tiles_*" /E /MT:32 /R:1 /W:1 /NFL /NDL /NP /XF "*.tmp" | Out-Null

# 2) Rebuild snaps.json with "tiles/tiles_YYYY-MM-DD"
Set-Location -LiteralPath $Repo
$sn = @()
Get-ChildItem -LiteralPath $tilesRoot -Directory | Sort-Object Name | ForEach-Object {
  $hasPng = Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter *.png -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($hasPng) {
    $sn += [pscustomobject]@{
      label = ($_.Name -replace '^tiles_','')
      dir   = ('tiles/' + $_.Name)
    }
  }
}
$sn | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath (Join-Path $Repo "snaps.json") -Encoding UTF8
Log ("snaps.json entries: {0}" -f $sn.Count)

# 3) Commit + push if changed
& git config --global --add safe.directory ($Repo -replace '\\','/')
$status = (& git status --porcelain)
if ([string]::IsNullOrWhiteSpace($status)) {
  Log "no changes; skipping push"
} else {
  & git add .
  & git commit -m ("publish: sync tiles/* + snaps.json ({0} dates)" -f $sn.Count) --allow-empty | Out-Null
  try {
    & git fetch origin | Out-Null
    & git pull --rebase origin main | Out-Null
  } catch { Log ("pull --rebase: " + $_.Exception.Message) }
  try {
    & git push -u origin main | Out-Null
    Log "push OK"
  } catch {
    Log ("push rejected: " + $_.Exception.Message)
    # optional: force-with-lease
    # & git push --force-with-lease -u origin main | Out-Null
  }
}

Log "=== publish done ==="
