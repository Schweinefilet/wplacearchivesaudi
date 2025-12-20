# Sync-Tiles-Optimized.ps1
# Space-efficient version: Download -> Push -> Delete
param(
  [string]$Owner = "murolem",
  [string]$Repo = "wplace-archives",
  [string]$TilesRoot = "tiles",
  [string]$TempDir = "/tmp/wplace-archive",
  [int]$XMin = 1245,
  [int]$XMax = 1254,
  [int]$YMin = 879,
  [int]$YMax = 903,
  [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

#region Utilities
function Log([string]$m) { Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor Cyan }
function LogSuccess([string]$m) { Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor Green }
function LogWarn([string]$m) { Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor Yellow }
function LogError([string]$m) { Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor Red }
function EnsureDir([string]$p) { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
#endregion

# Network
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

if (-not (Get-Command "tar" -ErrorAction SilentlyContinue)) {
  LogError "tar not found. Streaming extraction requires tar."
  exit 1
}

$token = $env:GITHUB_TOKEN
if ($token) { Log "Using GITHUB_TOKEN" } else { LogWarn "No GITHUB_TOKENfound" }

EnsureDir $TilesRoot
EnsureDir $TempDir

Write-Host "Syncing tiles X:$XMin-$XMax, Y:$YMin-$YMax" -ForegroundColor Magenta

#region Functions

function GetAllReleases {
  param([string]$Owner, [string]$Repo, [string]$Token)
  $allReleases = @()
  $page = 1
  $headers = @{ 'Accept' = 'application/vnd.github.v3+json' }
  if ($Token) { $headers['Authorization'] = "token $Token" }
    
  do {
    $releases = @()
    $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases?per_page=100&page=$page"
    try {
      $releases = @(Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing)
      if ($releases.Count -eq 0) { break }
      $allReleases += $releases
      $page++
    }
    catch {
      LogError "Failed to fetch page $page"
      break
    }
  } while ($releases.Count -eq 100)
  return $allReleases
}

function GetAvailableReleaseDates {
  param([array]$Releases)
  $dateLookup = @{}
  foreach ($rel in $Releases) {
    if ($rel.tag_name -match '(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})') {
      $dateStr = $Matches[1]
      $hour = [int]$Matches[2]
      if ($hour -ge 21) {
        if (-not $dateLookup.ContainsKey($dateStr) -or $rel.tag_name -gt $dateLookup[$dateStr].tag_name) {
          $dateLookup[$dateStr] = $rel
        }
      }
    }
  }
  return $dateLookup
}

function GetCommittedDates {
  $committedDates = @()
  try {
    $gitFiles = & git ls-tree -r HEAD --name-only "tiles/" 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitFiles) {
      foreach ($file in $gitFiles) {
        if ($file -match 'tiles/tiles_(\d{4}-\d{2}-\d{2})/') {
          $committedDates += $Matches[1]
        }
      }
    }
  }
  catch {
    LogWarn "Git error: $($_.Exception.Message)"
  }
  return $committedDates | Sort-Object -Unique
}

function DownloadAsset {
  param([string]$Url, [string]$OutFile, [string]$Token)
  $headers = @{ 'Accept' = 'application/octet-stream' }
  if ($Token) { $headers['Authorization'] = "token $Token" }
    
  try {
    $webClient = New-Object System.Net.WebClient
    foreach ($key in $headers.Keys) { $webClient.Headers.Add($key, $headers[$key]) }
    try {
      $webClient.DownloadFile($Url, $OutFile)
      return $true
    }
    finally {
      if ($null -ne $webClient) { $webClient.Dispose() }
    }
  }
  catch {
    LogError "Download failed: $($_.Exception.Message)"
    return $false
  }
}

function StreamExtractFiltered {
  param([string]$ArchiveFile, [string]$OutputDir, [int]$XMin, [int]$XMax, [int]$YMin, [int]$YMax)
  $filterFile = Join-Path $TempDir "filter_$(Get-Random).txt"
  try {
    $listing = & tar -tzf "$ArchiveFile" 2>$null
    $wanted = @()
    foreach ($entry in $listing) {
      if ($entry -match '/(\d+)/(\d+)\.png$') {
        $x = [int]$Matches[1]
        $y = [int]$Matches[2]
        if ($x -ge $XMin -and $x -le $XMax -and $y -ge $YMin -and $y -le $YMax) {
          $wanted += $entry
        }
      }
    }
        
    if ($wanted.Count -eq 0) {
      return 0
    }
        
    $wanted | Set-Content -LiteralPath $filterFile -Encoding UTF8
    & tar -xzf "$ArchiveFile" -C "$OutputDir" --strip-components=1 -T "$filterFile" 2>$null
    return $wanted.Count
  }
  finally {
    if (Test-Path $filterFile) { Remove-Item -LiteralPath $filterFile -Force -ErrorAction SilentlyContinue }
  }
}

function ProcessDate {
  param($DateStr, $Release, $TilesRoot, $TempDir, $XMin, $XMax, $YMin, $YMax, $Token, $WhatIf)
    
  $finalDir = Join-Path $TilesRoot "tiles_$DateStr"
  Log "[$DateStr] Processing release: $($Release.tag_name)"
    
  if ($WhatIf) {
    LogWarn "  [DRY-RUN] Would process $DateStr"
    return $true
  }
    
  $assets = $Release.assets | Where-Object { $_.name -match '\.tar\.gz\.(aa|ab|ac|ad|ae|af|ag|ah|ai|aj|ak|al|am|an|ao|ap)$' }
  if ($assets.Count -eq 0) {
    $assets = $Release.assets | Where-Object { $_.name -match '\.tar\.gz$' -and $_.name -notmatch '\.(aa|ab|ac)$' }
  }
  if ($assets.Count -eq 0) { return $false }
    
  $dateTempDir = Join-Path $TempDir "work_$DateStr"
  EnsureDir $dateTempDir
  EnsureDir $finalDir
    
  try {
    $archiveFile = $null
    if ($assets.Count -eq 1 -and $assets[0].name -match '\.tar\.gz$' -and $assets[0].name -notmatch '\.(aa|ab)$') {
      $archiveFile = Join-Path $dateTempDir $assets[0].name
      if (-not (DownloadAsset -Url $assets[0].browser_download_url -OutFile $archiveFile -Token $Token)) { return $false }
    }
    elseif ($assets.Count -eq 1 -and $assets[0].name -match '\.tar\.gz\.aa$') {
      $archiveFile = Join-Path $dateTempDir ($assets[0].name -replace '\.aa$', '')
      $tempPart = Join-Path $dateTempDir $assets[0].name
      if (-not (DownloadAsset -Url $assets[0].browser_download_url -OutFile $tempPart -Token $Token)) { return $false }
      Move-Item -LiteralPath $tempPart -Destination $archiveFile -Force
    }
    else {
      $baseName = ($assets[0].name -replace '\.(aa|ab|ac|ad|ae|af|ag|ah|ai|aj|ak|al|am|an|ao|ap)$', '')
      $archiveFile = Join-Path $dateTempDir $baseName
      $outStream = [System.IO.File]::OpenWrite($archiveFile)
      try {
        foreach ($asset in ($assets | Sort-Object name)) {
          $tempPart = Join-Path $dateTempDir $asset.name
          if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $tempPart -Token $Token)) { throw "Failed" }
          $inStream = [System.IO.File]::OpenRead($tempPart)
          try { $inStream.CopyTo($outStream) } finally { $inStream.Close() }
          Remove-Item -LiteralPath $tempPart -Force -ErrorAction SilentlyContinue
        }
      }
      finally { $outStream.Close() }
    }
        
    $count = StreamExtractFiltered -ArchiveFile $archiveFile -OutputDir $finalDir -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax
    Remove-Item -LiteralPath $archiveFile -Force -ErrorAction SilentlyContinue
    return ($count -gt 0)
  }
  finally {
    if (Test-Path $dateTempDir) { Remove-Item -LiteralPath $dateTempDir -Force -Recurse -ErrorAction SilentlyContinue }
  }
}

function UpdateSnapsJson {
  param($TilesRoot, $SnapsJsonPath = "snaps.json")
  $dates = @()
  $dates += GetCommittedDates
  $local = Get-ChildItem -Path $TilesRoot -Directory -Filter "tiles_*" -ErrorAction SilentlyContinue
  foreach ($d in $local) {
    if ($d.Name -match '^tiles_(\d{4}-\d{2}-\d{2})$') { $dates += $Matches[1] }
  }
  $snaps = $dates | Sort-Object -Unique | ForEach-Object { @{ label = $_; dir = "tiles/tiles_$_" } }
  if ($snaps.Count -gt 0) {
    $snaps | ConvertTo-Json -Depth 10 | Set-Content -Path $SnapsJsonPath -Encoding UTF8 -Force
  }
}

function GitCommitAndPush {
  param($DateStr, $WhatIf)
  if ($WhatIf) { return $true }
  try {
    & git add -A
    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { return $true }
    & git commit -m "tiles: $DateStr"
    if ($LASTEXITCODE -ne 0) { return $false }
    & git push
    return ($LASTEXITCODE -eq 0)
  }
  catch { return $false }
}

function DeleteLocalTiles {
  param($DateStr, $TilesRoot, $WhatIf)
  $tileDir = Join-Path $TilesRoot "tiles_$DateStr"
  if (Test-Path $tileDir) {
    if ($WhatIf) { LogWarn "[DRY-RUN] Would delete $DateStr" } else {
      Remove-Item -LiteralPath $tileDir -Force -Recurse -ErrorAction SilentlyContinue
      Log "Deleted $DateStr"
    }
  }
}

#endregion

#region Logic

Log "Fetching releases..."
$releases = GetAllReleases -Owner $Owner -Repo $Repo -Token $token
if (-not $releases) { exit 1 }

$available = GetAvailableReleaseDates -Releases $releases
$committed = GetCommittedDates

Log "Cleanup..."
$local = Get-ChildItem -Path $TilesRoot -Directory -Filter "tiles_*" -ErrorAction SilentlyContinue
foreach ($dir in $local) {
  if ($dir.Name -match '^tiles_(\d{4}-\d{2}-\d{2})$') {
    $ds = $Matches[1]
    if ($ds -in $committed) {
      DeleteLocalTiles -DateStr $ds -TilesRoot $TilesRoot -WhatIf:$WhatIf
    }
  }
}
UpdateSnapsJson -TilesRoot $TilesRoot

$needed = @($available.Keys | Where-Object { $_ -notin $committed } | Sort-Object)

if ($needed.Count -gt 0) {
  foreach ($d in $needed) {
    if (ProcessDate -DateStr $d -Release $available[$d] -TilesRoot $TilesRoot -TempDir $TempDir -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax -Token $token -WhatIf:$WhatIf) {
      UpdateSnapsJson -TilesRoot $TilesRoot
      if (GitCommitAndPush -DateStr $d -WhatIf:$WhatIf) {
        DeleteLocalTiles -DateStr $d -TilesRoot $TilesRoot -WhatIf:$WhatIf
      }
    }
  }
}
else {
  LogSuccess "Up to date"
}

LogSuccess "Done"

#endregion
