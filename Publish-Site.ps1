param(
  [string]$From = "E:\wplace-archive",  # where tiles_* are written by your join/extract
  [string]$Repo = "E:\wplace-site"      # your GitHub Pages repo working copy
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# --- logging ---
$stamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$logDir = Join-Path $Repo "logs"
if (!(Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log    = Join-Path $logDir "publish_$stamp.log"
function Log([string]$m){ $ts=(Get-Date).ToString("s"); "$ts  $m" | Tee-Object -FilePath $log -Append | Out-Null }

Log "=== publish start ==="
Log "From=$From  Repo=$Repo"

# --- 0) optional: ensure .nojekyll exists once ---
$nojekyll = Join-Path $Repo ".nojekyll"
if (!(Test-Path -LiteralPath $nojekyll)) { "" | Set-Content -LiteralPath $nojekyll -Encoding Ascii; Log "created .nojekyll" }

# --- 1) mirror new/changed tiles_* into the repo (fast, incremental) ---
# /E = include subdirs; /MT:32 = multithread; /R:1 /W:1 = quick retries; /NFL/NDL/NP = quiet
# We do NOT use /MIR to avoid accidental deletes; the site only grows.
Log "robocopy tiles_* -> repo"
& robocopy $From $Repo "tiles_*" /E /MT:32 /R:1 /W:1 /NFL /NDL /NP /XF "*.tmp" | Out-Null

# --- 2) regenerate snaps.json from folders that actually have PNGs ---
Set-Location -LiteralPath $Repo
$sn = @()
Get-ChildItem -Directory -Filter "tiles_*" | Sort-Object Name | ForEach-Object {
  $firstPng = Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter *.png -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($firstPng) {
    $sn += [pscustomobject]@{ label = ($_.Name -replace '^tiles_',''); dir = $_.Name }
  }
}
$sn | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath (Join-Path $Repo "snaps.json") -Encoding UTF8
Log ("snaps.json: {0} entries" -f $sn.Count)

# --- 3) commit & push if anything changed ---
& git config --global --add safe.directory ($Repo -replace '\\','/')

$status = (& git status --porcelain)
if ([string]::IsNullOrWhiteSpace($status)) {
  Log "no changes; skipping commit/push"
} else {
  Log "git add/commit/push…"
  & git add .
  & git commit -m ("publish: tiles sync + snaps.json ({0} dates)" -f $sn.Count) --allow-empty | Out-Null

  # Try a rebase pull to stay in sync; if it fails, we still try to push (fast-forward or reject).
  try {
    & git fetch origin | Out-Null
    & git pull --rebase origin main | Out-Null
  } catch { Log ("pull --rebase error: " + $_.Exception.Message) }

  try {
    & git push -u origin main | Out-Null
    Log "push OK"
  } catch {
    Log ("push rejected; attempting force-with-lease… " + $_.Exception.Message)
    # Uncomment next line only if you want local to overwrite remote:
    # & git push --force-with-lease -u origin main | Out-Null
  }
}

Log "=== publish done ==="
