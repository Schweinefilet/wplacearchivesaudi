# Get-MissingTarParts.ps1
param(
  [string]$Owner       = "murolem",
  [string]$Repo        = "wplace-archives",
  [string]$TilesRoot   = "E:\wplace-site\tiles",
  [string]$OutDir      = "E:\Downloads E",
  [datetime]$StartDate = ((Get-Date).AddDays(-120)).Date,
  [datetime]$EndDate   = (Get-Date).Date
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

function Log([string]$m){ Write-Host $m }
function Ensure-Dir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }

function Get-ExistingDates([string]$root){
  $set = [System.Collections.Generic.HashSet[string]]::new()
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
      ForEach-Object {
        if ($_.Name -match '^tiles[_-](\d{4}-\d{2}-\d{2})$') { [void]$set.Add($Matches[1]) }
        elseif ($_.Name -match '^(\d{4}-\d{2}-\d{2})$')     { [void]$set.Add($Matches[1]) }
      }
    Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.tar.gz -ErrorAction SilentlyContinue |
      ForEach-Object {
        if ($_.Name -match '^archive[_-](\d{4}-\d{2}-\d{2})\.tar\.gz$') { [void]$set.Add($Matches[1]) }
      }
  }
  return $set
}

function Extract-OnlyRange {
  param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$DestDir,
    [int]$KeepStart = 1243,
    [int]$KeepEnd   = 1258
  )
  if (-not (Get-Command tar -ErrorAction SilentlyContinue)) { throw "tar not found in PATH" }
  Ensure-Dir $DestDir

  # Build include patterns once. Tar will scan the archive a single time.
  $patterns = New-Object System.Collections.Generic.List[string]
  for ($n=$KeepStart; $n -le $KeepEnd; $n++){ $patterns.Add("*/$n/*.png") }

  Log ("  [TAR] selective extract -> {0}" -f $DestDir)
  & tar -xzf "$ArchivePath" -C "$DestDir" @patterns
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    # fallback without -z if gzip autodetect fails
    & tar -xf "$ArchivePath" -C "$DestDir" @patterns
    $code = $LASTEXITCODE
  }
  if ($code -ne 0) { Log ("  [WARN] tar exit code {0}" -f $code) }
}

# -------- GitHub fetch and process --------
$base  = "https://api.github.com"
$reUri = "$base/repos/$Owner/$Repo/releases?per_page=100&page="
$hdrs  = @{ "Accept"="application/vnd.github+json"; "User-Agent"="pwsh-wplace" }
if ($env:GITHUB_TOKEN) { $hdrs["Authorization"] = "Bearer $($env:GITHUB_TOKEN)"; Log "[INFO] Using GITHUB_TOKEN." } else { Log "[INFO] No GITHUB_TOKEN. You may hit API rate limits." }

# Fetch releases
$releases = @()
for ($page=1; $page -le 10; $page++){
  $r = Invoke-RestMethod -Uri ($reUri + $page) -Headers $hdrs -Method GET
  if (-not $r) { break }
  $releases += $r
  $last = $r | Select-Object -Last 1
  if ($last -and ([datetime]$last.created_at) -lt $StartDate.AddDays(-2)) { break }
}

# Group newest world-* per date
$grouped = @{}
foreach ($rel in ($releases | Where-Object { $_.tag_name -like 'world-*' })) {
  if ($rel.tag_name -match '^world-(\d{4}-\d{2}-\d{2})T') {
    $dStr = $Matches[1]
    $d = [datetime]::ParseExact($dStr,'yyyy-MM-dd',$null)
    if ($d -lt $StartDate -or $d -gt $EndDate) { continue }
    $pub = [datetime]$rel.published_at
    if (-not $grouped.ContainsKey($dStr) -or $grouped[$dStr].Published -lt $pub) {
      $grouped[$dStr] = [pscustomobject]@{ Release = $rel; Published = $pub }
    }
  }
}

if ($grouped.Count -eq 0) { Log "[INFO] No matching releases in window."; exit }

# Missing dates
$haveDates = Get-ExistingDates -root $TilesRoot
$missingDates = @($grouped.Keys | Where-Object { -not $haveDates.Contains($_) } | Sort-Object)
if ($missingDates.Count -eq 0) { Log "[OK] No missing dates."; exit }
Log ("[PLAN] Missing dates: {0}" -f ($missingDates -join ", "))

# Local inventory
Ensure-Dir $OutDir
$have = @{}
Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue | ForEach-Object {
  if (-not $have.ContainsKey($_.Name) -or $have[$_.Name] -lt $_.Length) { $have[$_.Name] = $_.Length }
}

foreach ($date in $missingDates) {
  try {
    $rel = $grouped[$date].Release
    Log ("[DATE] {0}  tag={1}  published={2}" -f $date, $rel.tag_name, [datetime]$rel.published_at)

    # Parts
    $assets = @($rel.assets | Where-Object { $_.name -match '\.tar\.gz\.((aa|ab|ac|ad|ae)|\d{3})$' })
    if (-not $assets -or $assets.Count -eq 0) { Log "  [WARN] no split parts found in release."; continue }

    foreach ($a in ($assets | Sort-Object name)) {
      $name = $a.name; $dst = Join-Path $OutDir $name; $apiSize = if ($a.size) { [int64]$a.size } else { $null }
      $need = $true
      if ($have.ContainsKey($name) -and $apiSize -and $have[$name] -eq $apiSize) { Log "  [HAVE] ${name} (size match)"; $need = $false }
      elseif ((Test-Path -LiteralPath $dst) -and $apiSize) {
        try { if ((Get-Item -LiteralPath $dst).Length -eq $apiSize) { Log "  [HAVE] ${name}"; $need = $false } } catch {}
      }
      if ($need) {
        Log "  [GET ] ${name}"
        Invoke-WebRequest -Uri $a.browser_download_url -OutFile $dst -UseBasicParsing -ErrorAction Stop
        if ($apiSize -and (Get-Item -LiteralPath $dst).Length -ne $apiSize) { throw "downloaded size mismatch" }
        if ($apiSize) { $have[$name] = $apiSize }; Log "  [OK  ] ${name}"
      }
    }

    # Join parts once
    $parts = @($assets | Sort-Object name | ForEach-Object { $p = Join-Path $OutDir $_.name; if (Test-Path -LiteralPath $p) { Get-Item -LiteralPath $p } })
    if (@($parts).Count -lt 2) { Log ("  [WARN] not enough parts to join for {0}." -f $date); continue }
    $joinedName = "archive_$date.tar.gz"; $joinedTemp = Join-Path $OutDir $joinedName
    Log ("  [JOIN] {0} parts -> {1}" -f @($parts).Count, $joinedTemp)
    Ensure-Dir ([System.IO.Path]::GetDirectoryName($joinedTemp))
    $fsOut = [System.IO.File]::Open($joinedTemp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { foreach ($pi in $parts) { $fsIn = [System.IO.File]::OpenRead($pi.FullName); try { $fsIn.CopyTo($fsOut) } finally { $fsIn.Dispose() } } } finally { $fsOut.Dispose() }

    # Extract only target tiles in one pass
    $dateDir = Join-Path $TilesRoot ("tiles_{0}" -f $date)
    Ensure-Dir $dateDir
    Extract-OnlyRange -ArchivePath $joinedTemp -DestDir $dateDir -KeepStart 1243 -KeepEnd 1258

    # Cleanup
    try { Remove-Item -LiteralPath $joinedTemp -Force } catch {}
    foreach ($pi in $parts) { try { Remove-Item -LiteralPath $pi.FullName -Force } catch {} }

    Log ("  [DONE] {0} processed." -f $date)
  } catch {
    Log ("  [ERR] date {0}: {1}" -f $date, $_.Exception.Message)
    continue
  }
}

Log "[DONE] All missing dates processed."
