# Sync-Tiles.ps1
# Unified script to ensure all dates have complete tile coverage (X=1243-1253, Y=875-904)
param(
  [string]$Owner       = "murolem",
  [string]$Repo        = "wplace-archives",
  [string]$TilesRoot   = "E:\wplace-site\tiles",
  [string]$TempDir     = "E:\wplace-archive",
  [datetime]$StartDate = ((Get-Date).AddDays(-120)).Date,
  [datetime]$EndDate   = (Get-Date).Date,
  [int]$XMin = 1243,
  [int]$XMax = 1253,
  [int]$YMin = 875,
  [int]$YMax = 904,
  [int]$ParallelJobs = 3
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Log([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" }
function EnsureDir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }

# Performance boost
try {
  $process = Get-Process -Id $PID
  $process.PriorityClass = 'High'
  [System.Threading.Thread]::CurrentThread.Priority = 'Highest'
  Log "[PERF] Running at HIGH priority"
} catch {
  Log "[WARN] Could not set high priority: $($_.Exception.Message)"
}

# Network tuning
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = 100
[Net.ServicePointManager]::Expect100Continue = $false
[Net.ServicePointManager]::UseNagleAlgorithm = $false
$ProgressPreference = 'SilentlyContinue'

# Check for tools
$use7z = (Get-Command "7z" -ErrorAction SilentlyContinue) -ne $null
$hasTar = (Get-Command "tar" -ErrorAction SilentlyContinue) -ne $null
if (-not $use7z -and -not $hasTar) {
  Log "[ERROR] Neither 7z nor tar found. Please install tar or 7zip."
  exit 1
}
if ($use7z) { Log "[INFO] Using 7z for extraction" }
else { Log "[INFO] Using tar for extraction" }

# Check for GitHub token
$token = $env:GITHUB_TOKEN
if ($token) { Log "[INFO] Using GITHUB_TOKEN." }
else { Log "[WARN] No GITHUB_TOKEN found. Rate limits may apply." }

EnsureDir $TilesRoot
EnsureDir $TempDir

Log "[REGION] Extracting x=$XMin-$XMax, y=$YMin-$YMax (Mecca/Medina/Taif)"

# Functions
function FilterYRange {
  param([string]$Root, [int]$YMin, [int]$YMax)
  if (-not (Test-Path $Root)) { return }
  $removed = 0
  Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $xDir = $_
    if ($xDir.Name -match '^\d+$') {
      Get-ChildItem -Path $xDir.FullName -File -Filter "*.png" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.BaseName -match '^\d+$') {
          $yVal = [int]($_.BaseName)
          if ($yVal -lt $YMin -or $yVal -gt $YMax) {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            $removed++
          }
        }
      }
      if (-not (Get-ChildItem -Path $xDir.FullName -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $xDir.FullName -Force -Recurse -ErrorAction SilentlyContinue
      }
    }
  }
  if ($removed -gt 0) { Log "  [FILTER] Removed $removed tiles outside Y=$YMin-$YMax" }
}

function FlattenToXY {
  param([string]$Root, [int]$XMin, [int]$XMax)
  if (-not (Test-Path $Root)) { return }
  
  # Recursively find all directories named as integers in the X range, regardless of depth
  $foundXDirs = @{}
  Get-ChildItem -Path $Root -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '^\d+$'
  } | ForEach-Object {
    $xVal = [int]($_.Name)
    if ($xVal -ge $XMin -and $xVal -le $XMax) {
      # Keep track of deepest instance of each X value (in case of duplicates)
      if (-not $foundXDirs.ContainsKey($xVal) -or $_.FullName.Length -gt $foundXDirs[$xVal].Length) {
        $foundXDirs[$xVal] = $_.FullName
      }
    }
  }
  
  # Move each found X directory to the root level
  foreach ($xVal in $foundXDirs.Keys) {
    $srcXDir = $foundXDirs[$xVal]
    $dstXDir = Join-Path $Root $xVal
    
    if ($srcXDir -eq $dstXDir) {
      # Already at root level, skip
      continue
    }
    
    if (Test-Path $dstXDir) {
      # Merge files
      Get-ChildItem -Path $srcXDir -File -Filter "*.png" -ErrorAction SilentlyContinue | ForEach-Object {
        $dstFile = Join-Path $dstXDir $_.Name
        if (-not (Test-Path $dstFile)) {
          Move-Item -LiteralPath $_.FullName -Destination $dstFile -Force -ErrorAction SilentlyContinue
        }
      }
      # Remove source after merge
      Remove-Item -LiteralPath $srcXDir -Force -Recurse -ErrorAction SilentlyContinue
    } else {
      # Move entire directory
      Move-Item -LiteralPath $srcXDir -Destination $dstXDir -Force -ErrorAction SilentlyContinue
    }
  }
  
  # Clean up any non-numeric directories at root level (prefixes that are now empty or irrelevant)
  Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -notmatch '^\d+$'
  } | ForEach-Object {
    if (-not (Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
      Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
    }
  }
}

function GetMissingXFolders {
  param([string]$DateDir, [int]$XMin, [int]$XMax)
  $missing = @()
  for ($x = $XMin; $x -le $XMax; $x++) {
    $xDir = Join-Path $DateDir $x
    if (-not (Test-Path $xDir)) {
      $missing += $x
    }
  }
  return ,$missing
}

function DownloadAsset {
  param([string]$Url, [string]$OutFile, [string]$Token)
  $headers = @{ 'Accept' = 'application/octet-stream' }
  if ($Token) { $headers['Authorization'] = "token $Token" }
  
  try {
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -Headers $headers -UseBasicParsing
    return $true
  } catch {
    Log "  [ERROR] Download failed: $($_.Exception.Message)"
    return $false
  }
}

function ProcessDate {
  param(
    [string]$Date,
    [array]$MissingX,
    [string]$TilesRoot,
    [string]$TempDir,
    [int]$XMin,
    [int]$XMax,
    [int]$YMin,
    [int]$YMax,
    [bool]$Use7z,
    [string]$Token,
    [string]$Owner,
    [string]$Repo
  )
  
  $dateStr = $Date
  $finalDir = Join-Path $TilesRoot "tiles_$dateStr"
  
    if ($MissingX.Count -eq 0) {
    Log "[$dateStr] Already complete (X=$XMin-$XMax)"
    return
  }

  if ($MissingX.Count -eq ($XMax - $XMin + 1)) {
    Log "[$dateStr] Completely missing, downloading full archive..."
  } else {
    # Flatten any nested arrays so we don't get 'System.Object[]' when stringifying
    $missingFlat = @()
    foreach ($m in $MissingX) {
      if ($m -is [System.Array]) { $missingFlat += $m } else { $missingFlat += $m }
    }
    $missingStr = ($missingFlat | ForEach-Object { $_ }) -join ","
    Log "[$dateStr] Missing X folders: $missingStr"
  }
  
  # Find release tag
  $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases"
  $headers = @{ 'Accept' = 'application/vnd.github.v3+json' }
  if ($Token) { $headers['Authorization'] = "token $Token" }
  
  try {
    $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing
  } catch {
    Log "  [ERROR] Failed to fetch releases: $($_.Exception.Message)"
    return
  }
  
  # Find all releases for this date and pick the latest one
  $matchingReleases = $releases | Where-Object { $_.tag_name -match $dateStr }
  if ($matchingReleases.Count -eq 0) {
    Log "  [WARN] No release found for $dateStr"
    return
  }
  
  # Sort by tag_name descending (later timestamps sort higher) and take the first
  $release = $matchingReleases | Sort-Object tag_name -Descending | Select-Object -First 1
  
  if ($matchingReleases.Count -gt 1) {
    Log "  [FOUND] Release: $($release.tag_name) (picked latest of $($matchingReleases.Count) releases)"
  } else {
    Log "  [FOUND] Release: $($release.tag_name)"
  }
  
  # Get archive assets
  $assets = $release.assets | Where-Object { $_.name -match '\.tar\.gz\.(aa|ab|ac|ad|ae|af|ag|ah|ai|aj|ak|al|am|an|ao|ap)$' }
  
  # Handle single-file archives (no .aa/.ab split)
  if ($assets.Count -eq 0) {
    $assets = $release.assets | Where-Object { $_.name -match '\.tar\.gz$' -and $_.name -notmatch '\.(aa|ab|ac)$' }
  }
  
  if ($assets.Count -eq 0) {
    Log "  [WARN] No archive assets found"
    return
  }
  
  # Download and extract
  $tempExtract = Join-Path $TempDir "extract_$dateStr"
  EnsureDir $tempExtract
  
  try {
    if ($assets.Count -eq 1 -and $assets[0].name -match '\.tar\.gz$' -and $assets[0].name -notmatch '\.(aa|ab)$') {
      # Single complete archive
      $asset = $assets[0]
      $outFile = Join-Path $TempDir $asset.name
      
      # Skip download if file already exists and has correct size
      $needsDownload = $true
      if ((Test-Path $outFile) -and (Get-Item $outFile).Length -eq $asset.size) {
        Log "  [SKIP] Archive already downloaded: $($asset.name)"
        $needsDownload = $false
      }
      
      if ($needsDownload) {
        Log "  [DOWNLOAD] Single archive: $($asset.name) ($([math]::Round($asset.size/1MB, 2)) MB)"
        if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $outFile -Token $Token)) {
          return
        }
      }
      
      # Extract directly
      Log "  [EXTRACT] Extracting archive..."
      if ($Use7z) {
        & 7z x "$outFile" -o"$tempExtract" -y -bb0 -bd | Out-Null
      } else {
        Push-Location $tempExtract
        try {
          tar -xzf "$outFile" 2>$null
        } finally {
          Pop-Location
        }
      }
      
      Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
      
    } elseif ($assets.Count -eq 1 -and $assets[0].name -match '\.tar\.gz\.aa$') {
      # Single part of a multi-part archive (only .aa exists)
      $asset = $assets[0]
      $baseName = $asset.name -replace '\.aa$', ''
      $outFile = Join-Path $TempDir $asset.name
      
      # Skip download if file already exists and has correct size
      $needsDownload = $true
      if ((Test-Path $outFile) -and (Get-Item $outFile).Length -eq $asset.size) {
        Log "  [SKIP] Single part already downloaded: $($asset.name)"
        $needsDownload = $false
      }
      
      if ($needsDownload) {
        Log "  [DOWNLOAD] Single part: $($asset.name) ($([math]::Round($asset.size/1MB, 2)) MB)"
        if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $outFile -Token $Token)) {
          return
        }
      }
      
      # Treat as complete archive (no joining needed)
      $joinedFile = Join-Path $TempDir $baseName
      Move-Item -LiteralPath $outFile -Destination $joinedFile -Force
      
      Log "  [EXTRACT] Extracting archive..."
      if ($Use7z) {
        & 7z x "$joinedFile" -o"$tempExtract" -y -bb0 -bd | Out-Null
      } else {
        Push-Location $tempExtract
        try {
          tar -xzf "$joinedFile" 2>$null
        } finally {
          Pop-Location
        }
      }
      
      Remove-Item -LiteralPath $joinedFile -Force -ErrorAction SilentlyContinue
      
    } else {
      # Multi-part archive
      $parts = @()
      foreach ($asset in $assets) {
        $outFile = Join-Path $TempDir $asset.name
        
        # Skip download if file already exists and has correct size
        if ((Test-Path $outFile) -and (Get-Item $outFile).Length -eq $asset.size) {
          Log "  [SKIP] Part already downloaded: $($asset.name)"
          $parts += $outFile
          continue
        }
        
        Log "  [DOWNLOAD] Part: $($asset.name) ($([math]::Round($asset.size/1MB, 2)) MB)"
        
        if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $outFile -Token $Token)) {
          return
        }
        $parts += $outFile
      }
      
      # Join parts
      $baseName = ($assets[0].name -replace '\.(aa|ab|ac|ad|ae|af|ag|ah|ai|aj|ak|al|am|an|ao|ap)$', '')
      $joinedFile = Join-Path $TempDir $baseName
      
      Log "  [JOIN] Combining $($parts.Count) parts..."
      $outStream = [System.IO.File]::OpenWrite($joinedFile)
      try {
        foreach ($part in ($parts | Sort-Object)) {
          $inStream = [System.IO.File]::OpenRead($part)
          try {
            $inStream.CopyTo($outStream)
          } finally {
            $inStream.Close()
          }
        }
      } finally {
        $outStream.Close()
      }
      
      # Clean up parts
      foreach ($part in $parts) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
      }
      
      # Extract
      Log "  [EXTRACT] Extracting archive..."
      if ($Use7z) {
        & 7z x "$joinedFile" -o"$tempExtract" -y -bb0 -bd | Out-Null
      } else {
        Push-Location $tempExtract
        try {
          tar -xzf "$joinedFile" 2>$null
        } finally {
          Pop-Location
        }
      }
      
      Remove-Item -LiteralPath $joinedFile -Force -ErrorAction SilentlyContinue
    }
    
      # Debug: show what was extracted at top level (helps diagnose missing X dirs)
    try {
      $topEntries = Get-ChildItem -Path $tempExtract -Force -ErrorAction SilentlyContinue | Select-Object -First 20
      if ($topEntries -and $topEntries.Count -gt 0) {
        $names = $topEntries | ForEach-Object { $_.Name } -join ","
        Log "  [DEBUG] Extracted top-level entries: $names"
      } else {
        Log "  [DEBUG] No top-level entries found in $tempExtract"
      }
    } catch {
      $errMsg = $_.Exception.Message
      Log "  [DEBUG] Failed to list ${tempExtract}: $errMsg"
    }

    # Flatten structure
    FlattenToXY -Root $tempExtract -XMin $XMin -XMax $XMax
    
    # Move only missing X folders
    EnsureDir $finalDir
    $moved = 0
      foreach ($x in $MissingX) {
      # Ensure $x is a valid value
      if ([string]::IsNullOrEmpty($x)) { continue }

      $srcXDir = Join-Path $tempExtract ([string]$x)
      if (Test-Path $srcXDir) {
        $dstXDir = Join-Path $finalDir ([string]$x)
        if (Test-Path $dstXDir) {
          # Merge
          Get-ChildItem -Path $srcXDir -File -Filter "*.png" | ForEach-Object {
            $dstFile = Join-Path $dstXDir $_.Name
            if (-not (Test-Path $dstFile)) {
              Move-Item -LiteralPath $_.FullName -Destination $dstFile -Force
              $moved++
            }
          }
        } else {
          Move-Item -LiteralPath $srcXDir -Destination $dstXDir -Force
          $movedCount = (Get-ChildItem -Path $dstXDir -File -Filter "*.png" -Recurse -ErrorAction SilentlyContinue).Count
          $moved += $movedCount
        }
      } else {
        Log "  [MISS] Extracted archive did not contain X=$x (looking for $srcXDir)"
      }
    }
    
    # Filter Y range
    FilterYRange -Root $finalDir -YMin $YMin -YMax $YMax
    
    $finalCount = (Get-ChildItem -Path $finalDir -File -Filter "*.png" -Recurse -ErrorAction SilentlyContinue).Count
    Log "  [DONE] $dateStr - Added $moved tiles (total: $finalCount)"
    
  } finally {
    if (Test-Path $tempExtract) {
      Remove-Item -LiteralPath $tempExtract -Force -Recurse -ErrorAction SilentlyContinue
    }
  }
}

# Main execution
Log "========================================="
Log "Tile Sync - Ensure Complete Coverage"
Log "========================================="

# Scan existing tiles
$allDates = @()
for ($d = $StartDate; $d -le $EndDate; $d = $d.AddDays(1)) {
  $dateStr = $d.ToString('yyyy-MM-dd')
  $dateDir = Join-Path $TilesRoot "tiles_$dateStr"
  
  $missingX = @()
  if (Test-Path $dateDir) {
    $missingX = @(GetMissingXFolders -DateDir $dateDir -XMin $XMin -XMax $XMax)
  } else {
    # Entire date missing
    $missingX = @($XMin..$XMax)
  }
  
  if (@($missingX).Count -gt 0) {
    $allDates += @{
      Date = $dateStr
      MissingX = $missingX
    }
  }
}

if ($allDates.Count -eq 0) {
  Log "[SUCCESS] All dates are complete! Nothing to do."
  exit 0
}

Log "[PLAN] Found $($allDates.Count) dates needing work"

# Process dates
if ($ParallelJobs -gt 1) {
  Log "[PERF] Processing with $ParallelJobs parallel jobs"
  
  $allDates | ForEach-Object -Parallel {
    $dateInfo = $_
    $tilesRoot = $using:TilesRoot
    $tempDir = $using:TempDir
    $xMin = $using:XMin
    $xMax = $using:XMax
    $yMin = $using:YMin
    $yMax = $using:YMax
    $use7z = $using:use7z
    $token = $using:token
    $owner = $using:Owner
    $repo = $using:Repo
    
    # Redefine functions in parallel scope
    function Log([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" }
    function EnsureDir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
    
    function FilterYRange {
      param([string]$Root, [int]$YMin, [int]$YMax)
      if (-not (Test-Path $Root)) { return }
      $removed = 0
      Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $xDir = $_
        if ($xDir.Name -match '^\d+$') {
          Get-ChildItem -Path $xDir.FullName -File -Filter "*.png" -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.BaseName -match '^\d+$') {
              $yVal = [int]($_.BaseName)
              if ($yVal -lt $YMin -or $yVal -gt $YMax) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                $removed++
              }
            }
          }
          if (-not (Get-ChildItem -Path $xDir.FullName -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $xDir.FullName -Force -Recurse -ErrorAction SilentlyContinue
          }
        }
      }
      if ($removed -gt 0) { Log "  [FILTER] Removed $removed tiles outside Y=$YMin-$YMax" }
    }
    
    function FlattenToXY {
      param([string]$Root, [int]$XMin, [int]$XMax)
      if (-not (Test-Path $Root)) { return }
      
      # Recursively find all directories named as integers in the X range, regardless of depth
      $foundXDirs = @{}
      Get-ChildItem -Path $Root -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^\d+$'
      } | ForEach-Object {
        $xVal = [int]($_.Name)
        if ($xVal -ge $XMin -and $xVal -le $XMax) {
          # Keep track of deepest instance of each X value (in case of duplicates)
          if (-not $foundXDirs.ContainsKey($xVal) -or $_.FullName.Length -gt $foundXDirs[$xVal].Length) {
            $foundXDirs[$xVal] = $_.FullName
          }
        }
      }
      
      # Move each found X directory to the root level
      foreach ($xVal in $foundXDirs.Keys) {
        $srcXDir = $foundXDirs[$xVal]
        $dstXDir = Join-Path $Root $xVal
        
        if ($srcXDir -eq $dstXDir) {
          # Already at root level, skip
          continue
        }
        
        if (Test-Path $dstXDir) {
          # Merge files
          Get-ChildItem -Path $srcXDir -File -Filter "*.png" -ErrorAction SilentlyContinue | ForEach-Object {
            $dstFile = Join-Path $dstXDir $_.Name
            if (-not (Test-Path $dstFile)) {
              Move-Item -LiteralPath $_.FullName -Destination $dstFile -Force -ErrorAction SilentlyContinue
            }
          }
          # Remove source after merge
          Remove-Item -LiteralPath $srcXDir -Force -Recurse -ErrorAction SilentlyContinue
        } else {
          # Move entire directory
          Move-Item -LiteralPath $srcXDir -Destination $dstXDir -Force -ErrorAction SilentlyContinue
        }
      }
      
      # Clean up any non-numeric directories at root level (prefixes that are now empty or irrelevant)
      Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notmatch '^\d+$'
      } | ForEach-Object {
        if (-not (Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
          Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
        }
      }
    }
    
    function DownloadAsset {
      param([string]$Url, [string]$OutFile, [string]$Token)
      $headers = @{ 'Accept' = 'application/octet-stream' }
      if ($Token) { $headers['Authorization'] = "token $Token" }
      try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -Headers $headers -UseBasicParsing
        return $true
      } catch {
        Log "  [ERROR] Download failed: $($_.Exception.Message)"
        return $false
      }
    }
    
    # Process this date
    $dateStr = $dateInfo.Date
    $missingX = $dateInfo.MissingX
    $finalDir = Join-Path $tilesRoot "tiles_$dateStr"
    
    if ($missingX.Count -eq 0) {
      Log "[$dateStr] Already complete"
      return
    }

    if ($missingX.Count -eq ($xMax - $xMin + 1)) {
      Log "[$dateStr] Completely missing, downloading full archive..."
    } else {
      # Flatten nested arrays in case the MissingX value is wrapped
      $missingFlat = @()
      foreach ($m in $missingX) {
        if ($m -is [System.Array]) { $missingFlat += $m } else { $missingFlat += $m }
      }
      $missingStr = ($missingFlat | ForEach-Object { $_ }) -join ","
      Log "[$dateStr] Missing X folders: $missingStr"
    }
    
    # Find release
    $apiUrl = "https://api.github.com/repos/$owner/$repo/releases"
    $headers = @{ 'Accept' = 'application/vnd.github.v3+json' }
    if ($token) { $headers['Authorization'] = "token $token" }
    
    try {
      $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing
    } catch {
      Log "  [ERROR] Failed to fetch releases: $($_.Exception.Message)"
      return
    }
    
    # Find all releases for this date and pick the latest one
    $matchingReleases = $releases | Where-Object { $_.tag_name -match $dateStr }
    if ($matchingReleases.Count -eq 0) {
      Log "  [WARN] No release found for $dateStr"
      return
    }
    
    # Sort by tag_name descending (later timestamps sort higher) and take the first
    $release = $matchingReleases | Sort-Object tag_name -Descending | Select-Object -First 1
    
    if ($matchingReleases.Count -gt 1) {
      Log "  [FOUND] Release: $($release.tag_name) (picked latest of $($matchingReleases.Count) releases)"
    } else {
      Log "  [FOUND] Release: $($release.tag_name)"
    }
    
    # Get assets
    $assets = $release.assets | Where-Object { $_.name -match '\.tar\.gz\.(aa|ab|ac|ad|ae|af|ag|ah|ai|aj|ak|al|am|an|ao|ap)$' }
    if ($assets.Count -eq 0) {
      $assets = $release.assets | Where-Object { $_.name -match '\.tar\.gz$' -and $_.name -notmatch '\.(aa|ab)$' }
    }
    
    if ($assets.Count -eq 0) {
      Log "  [WARN] No archive assets found"
      return
    }
    
    # Download and extract
    $tempExtract = Join-Path $tempDir "extract_$dateStr"
    EnsureDir $tempExtract
    
    try {
      if ($assets.Count -eq 1 -and $assets[0].name -match '\.tar\.gz$' -and $assets[0].name -notmatch '\.(aa|ab)$') {
        # Single complete archive
        $asset = $assets[0]
        $outFile = Join-Path $tempDir $asset.name
        
        $needsDownload = $true
        if ((Test-Path $outFile) -and (Get-Item $outFile).Length -eq $asset.size) {
          Log "  [SKIP] Archive already downloaded: $($asset.name)"
          $needsDownload = $false
        }
        
        if ($needsDownload) {
          Log "  [DOWNLOAD] Single archive: $($asset.name) ($([math]::Round($asset.size/1MB, 2)) MB)"
          if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $outFile -Token $token)) { return }
        }
        
        Log "  [EXTRACT] Extracting..."
        if ($use7z) {
          & 7z x "$outFile" -o"$tempExtract" -y -bb0 -bd | Out-Null
        } else {
          Push-Location $tempExtract
          try { tar -xzf "$outFile" 2>$null } finally { Pop-Location }
        }
        
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        
      } elseif ($assets.Count -eq 1 -and $assets[0].name -match '\.tar\.gz\.aa$') {
        # Single .aa part (treat as complete)
        $asset = $assets[0]
        $baseName = $asset.name -replace '\.aa$', ''
        $outFile = Join-Path $tempDir $asset.name
        
        $needsDownload = $true
        if ((Test-Path $outFile) -and (Get-Item $outFile).Length -eq $asset.size) {
          Log "  [SKIP] Single part already downloaded: $($asset.name)"
          $needsDownload = $false
        }
        
        if ($needsDownload) {
          Log "  [DOWNLOAD] Single part: $($asset.name) ($([math]::Round($asset.size/1MB, 2)) MB)"
          if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $outFile -Token $token)) { return }
        }
        
        $joinedFile = Join-Path $tempDir $baseName
        Move-Item -LiteralPath $outFile -Destination $joinedFile -Force
        
        Log "  [EXTRACT] Extracting..."
        if ($use7z) {
          & 7z x "$joinedFile" -o"$tempExtract" -y -bb0 -bd | Out-Null
        } else {
          Push-Location $tempExtract
          try { tar -xzf "$joinedFile" 2>$null } finally { Pop-Location }
        }

        Remove-Item -LiteralPath $joinedFile -Force -ErrorAction SilentlyContinue
        
      } else {
        # Multi-part
        $parts = @()
        foreach ($asset in $assets) {
          $outFile = Join-Path $tempDir $asset.name
          
          if ((Test-Path $outFile) -and (Get-Item $outFile).Length -eq $asset.size) {
            Log "  [SKIP] Part already downloaded: $($asset.name)"
            $parts += $outFile
            continue
          }
          
          Log "  [DOWNLOAD] Part: $($asset.name) ($([math]::Round($asset.size/1MB, 2)) MB)"
          if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $outFile -Token $token)) { return }
          $parts += $outFile
        }
        
        $baseName = ($assets[0].name -replace '\.(aa|ab|ac|ad|ae|af|ag|ah|ai|aj|ak|al|am|an|ao|ap)$', '')
        $joinedFile = Join-Path $tempDir $baseName
        
        Log "  [JOIN] Combining $($parts.Count) parts..."
        $outStream = [System.IO.File]::OpenWrite($joinedFile)
        try {
          foreach ($part in ($parts | Sort-Object)) {
            $inStream = [System.IO.File]::OpenRead($part)
            try { $inStream.CopyTo($outStream) } finally { $inStream.Close() }
          }
        } finally { $outStream.Close() }
        
        foreach ($part in $parts) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        
        Log "  [EXTRACT] Extracting..."
        if ($use7z) {
          & 7z x "$joinedFile" -o"$tempExtract" -y -bb0 -bd | Out-Null
        } else {
          Push-Location $tempExtract
          try { tar -xzf "$joinedFile" 2>$null } finally { Pop-Location }
        }
        
        Remove-Item -LiteralPath $joinedFile -Force -ErrorAction SilentlyContinue
      }
      
      # Debug: show top-level extracted entries (parallel)
      try {
        $topEntries = Get-ChildItem -Path $tempExtract -Force -ErrorAction SilentlyContinue | Select-Object -First 20
        if ($topEntries -and $topEntries.Count -gt 0) {
          $names = $topEntries | ForEach-Object { $_.Name } -join ","
          Log "  [DEBUG] Extracted top-level entries: $names"
        } else {
          Log "  [DEBUG] No top-level entries found in $tempExtract"
        }
      } catch {
        $errMsg = $_.Exception.Message
        Log "  [DEBUG] Failed to list ${tempExtract}: $errMsg"
      }

      # Flatten and move
      FlattenToXY -Root $tempExtract -XMin $xMin -XMax $xMax
      
      EnsureDir $finalDir
      $moved = 0
      foreach ($x in $missingX) {
        if ([string]::IsNullOrEmpty($x)) { continue }

        $srcXDir = Join-Path $tempExtract ([string]$x)
        if (Test-Path $srcXDir) {
          $dstXDir = Join-Path $finalDir ([string]$x)
          if (Test-Path $dstXDir) {
            Get-ChildItem -Path $srcXDir -File -Filter "*.png" | ForEach-Object {
              $dstFile = Join-Path $dstXDir $_.Name
              if (-not (Test-Path $dstFile)) {
                Move-Item -LiteralPath $_.FullName -Destination $dstFile -Force
                $moved++
              }
            }
          } else {
            Move-Item -LiteralPath $srcXDir -Destination $dstXDir -Force
            $movedCount = (Get-ChildItem -Path $dstXDir -File -Filter "*.png" -Recurse -ErrorAction SilentlyContinue).Count
            $moved += $movedCount
          }
        } else {
          Log "  [MISS] Extracted archive did not contain X=$x (looking for $srcXDir)"
        }
      }
      
      FilterYRange -Root $finalDir -YMin $yMin -YMax $yMax
      
      $finalCount = (Get-ChildItem -Path $finalDir -File -Filter "*.png" -Recurse -ErrorAction SilentlyContinue).Count
      Log "  [DONE] $dateStr - Added $moved tiles (total: $finalCount)"
      
    } finally {
      if (Test-Path $tempExtract) {
        Remove-Item -LiteralPath $tempExtract -Force -Recurse -ErrorAction SilentlyContinue
      }
    }
  } -ThrottleLimit $ParallelJobs
  
} else {
  Log "[START] Processing sequentially..."
  foreach ($dateInfo in $allDates) {
    ProcessDate -Date $dateInfo.Date -MissingX $dateInfo.MissingX `
                -TilesRoot $TilesRoot -TempDir $TempDir `
                -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax `
                -Use7z $use7z -Token $token -Owner $Owner -Repo $Repo
  }
}

Log "[COMPLETE] All dates processed!"
