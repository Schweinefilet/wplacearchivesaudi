# Get-MissingTarParts.ps1
param(
  [string]$Owner       = "murolem",
  [string]$Repo        = "wplace-archives",
  [string]$TilesRoot   = "E:\wplace-site\tiles",
  [string]$OutDir      = "E:\Downloads E",
  [datetime]$StartDate = ((Get-Date).AddDays(-120)).Date,
  [datetime]$EndDate   = (Get-Date).Date,
  [int]$XMin = 1243,
  [int]$XMax = 1250,
  [int]$YMin = 875,
  [int]$YMax = 904
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

function Remove-EmptyPngs {
  param([Parameter(Mandatory)][string]$Root)
  # Remove any 0-byte PNGs that might have been created
  Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "*.png" -ErrorAction SilentlyContinue | 
    Where-Object { $_.Length -eq 0 } | 
    Remove-Item -Force -ErrorAction SilentlyContinue
}

function Filter-YRange {
  param([Parameter(Mandatory)][string]$Root,[int]$YMin=875,[int]$YMax=904)
  $removed = 0
  Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | 
    Where-Object { $_.Name -match '^\d+$' } |
    ForEach-Object {
      $xDir = $_.FullName
      Get-ChildItem -LiteralPath $xDir -File -Filter "*.png" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.BaseName -match '^\d+$') {
          $y = [int]$_.BaseName
          if ($y -lt $YMin -or $y -gt $YMax) {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            $removed++
          }
        }
      }
    }
  if ($removed -gt 0) { Log ("  [FILTER] removed {0} tiles outside y={1}-{2}" -f $removed, $YMin, $YMax) }
}

function Flatten-Numeric {
  param([Parameter(Mandatory)][string]$Root,[int]$XMin=1243,[int]$XMax=1250,[int]$YMin=875,[int]$YMax=904)
  Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -notmatch '^\d+$') {
      Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+$' -and [int]$_.Name -ge $XMin -and [int]$_.Name -le $XMax } |
        ForEach-Object {
          $src = $_.FullName
          $dst = Join-Path $Root $_.Name
          if (-not (Test-Path -LiteralPath $dst)) {
            Move-Item -LiteralPath $src -Destination $dst -Force
          } else {
            # merge into existing numeric dir
            & robocopy "$src" "$dst" /E /MOV /NFL /NDL /NJH /NJS > $null
            try { Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction SilentlyContinue } catch {}
          }
        }
      try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
  # Filter Y coordinates after flattening
  Filter-YRange -Root $Root -YMin $YMin -YMax $YMax
}

function Get-StripComponents {
  param([Parameter(Mandatory)][string]$ArchivePath,[int]$XMin=1243,[int]$XMax=1250)
  $members = & tar -tzf "$ArchivePath" 2>$null; if (-not $members) { $members = & tar -tf "$ArchivePath" }
  $strip = 0
  foreach ($m in $members) {
    if (-not $m -or $m[-1] -eq '/') { continue }
    $segs = $m.TrimEnd('/') -split '/'
    for ($i=0; $i -lt $segs.Count; $i++) {
      if ($segs[$i] -match '^\d+$') {
        $num = [int]$segs[$i]
        if ($num -ge $XMin -and $num -le $XMax) { return $i }
      }
    }
  }
  return 0
}

function Extract-OnlyRange {
  param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$DestDir,
    [int]$XMin = 1243,
    [int]$XMax = 1250,
    [int]$YMin = 875,
    [int]$YMax = 904
  )
  Ensure-Dir $DestDir

  # Try 7z first (faster for selective extraction)
  $has7z = Get-Command 7z -ErrorAction SilentlyContinue
  if ($has7z) {
    $includes = @(); for ($n=$XMin; $n -le $XMax; $n++){ $includes += "-i!*/$n/*.png" }
    Log ("  [7Z] selective extract x={0}-{1}, y={2}-{3} -> {4}" -f $XMin, $XMax, $YMin, $YMax, $DestDir)
    & 7z x -bd -y -so -- "$ArchivePath" | & 7z x -bd -y -si -ttar "-o$DestDir" @includes
    if ($LASTEXITCODE -ne 0) { throw "7z selective extract failed with code $LASTEXITCODE" }
    Flatten-Numeric -Root $DestDir -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax
    Remove-EmptyPngs -Root $DestDir
    return
  }

  # Fallback to tar
  if (-not (Get-Command tar -ErrorAction SilentlyContinue)) { throw "Neither tar nor 7z found in PATH" }

  # Build patterns and compute how many leading components to strip
  $patterns = New-Object System.Collections.Generic.List[string]
  for ($n=$XMin; $n -le $XMax; $n++){
    $patterns.Add("*/$n/*.png"); $patterns.Add("*/*/$n/*.png")
  }
  $strip = Get-StripComponents -ArchivePath $ArchivePath -XMin $XMin -XMax $XMax

  Log ("  [TAR] selective extract x={0}-{1} (strip {2}) -> {3}" -f $XMin, $XMax, $strip, $DestDir)
  & tar --extract --gzip --file "$ArchivePath" --strip-components=$strip -C "$DestDir" @patterns 2>$null
  if ($LASTEXITCODE -ne 0) {
    & tar --extract --file "$ArchivePath" --strip-components=$strip -C "$DestDir" @patterns 2>$null
  }
  # Filter Y coordinates after extraction
  Filter-YRange -Root $DestDir -YMin $YMin -YMax $YMax
  Remove-EmptyPngs -Root $DestDir
}

# -------- GitHub fetch and process --------
$base  = "https://api.github.com"
$reUri = "$base/repos/$Owner/$Repo/releases?per_page=100&page="
$hdrs  = @{ "Accept"="application/vnd.github+json"; "User-Agent"="pwsh-wplace" }
if ($env:GITHUB_TOKEN) { $hdrs["Authorization"] = "Bearer $($env:GITHUB_TOKEN)"; Log "[INFO] Using GITHUB_TOKEN." } 
else { Log "[INFO] No GITHUB_TOKEN set. You may hit API rate limits." }

Log ("[REGION] Extracting x={0}-{1}, y={2}-{3} (Mecca/Medina/Taif)" -f $XMin, $XMax, $YMin, $YMax)

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

    # Extract filtered tiles
    $dateDir = Join-Path $TilesRoot ("tiles_{0}" -f $date)
    Ensure-Dir $dateDir
    Extract-OnlyRange -ArchivePath $joinedTemp -DestDir $dateDir -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax

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
