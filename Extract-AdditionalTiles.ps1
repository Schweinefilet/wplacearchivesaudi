# Extract-AdditionalTiles.ps1
# Extracts missing X coordinates (1251-1253) from existing tar.gz files
param(
  [string]$TarGzDir    = "E:\Downloads E",
  [string]$TilesRoot   = "E:\wplace-site\tiles",
  [string]$TempDir     = "E:\wplace-archive",
  [int]$XMin = 1251,
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
[System.Net.ServicePointManager]::DefaultConnectionLimit = 100
[System.Net.ServicePointManager]::Expect100Continue = $false
[System.Net.ServicePointManager]::UseNagleAlgorithm = $false

# Check for tools
$use7z = (Get-Command "7z" -ErrorAction SilentlyContinue) -ne $null
$hasTar = (Get-Command "tar" -ErrorAction SilentlyContinue) -ne $null

if (-not $use7z -and -not $hasTar) {
  Log "[ERROR] Neither 7z nor tar found. Please install tar or 7zip."
  exit 1
}

if ($use7z) {
  Log "[INFO] Using 7z for extraction"
} else {
  Log "[INFO] Using tar for extraction"
}

# Filter function to remove tiles outside Y range
function FilterYRange {
  param([string]$RootPath, [int]$YMin, [int]$YMax)
  
  if (-not (Test-Path $RootPath)) { return }
  
  $removed = 0
  Get-ChildItem -Path $RootPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
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
      # Remove empty X directories
      if (-not (Get-ChildItem -Path $xDir.FullName -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $xDir.FullName -Force -Recurse -ErrorAction SilentlyContinue
      }
    }
  }
  
  if ($removed -gt 0) {
    Log "  [FILTER] Removed $removed tiles outside Y=$YMin-$YMax"
  }
}

# Flatten nested directory structure (handle prefix/X/Y.png -> X/Y.png)
function FlattenToXY {
  param([string]$RootPath, [int]$XMin, [int]$XMax)
  
  if (-not (Test-Path $RootPath)) { return }
  
  # Find any non-numeric top-level directories (date prefixes)
  Get-ChildItem -Path $RootPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -notmatch '^\d+$') {
      $prefixDir = $_
      # Look for numeric X directories inside
      Get-ChildItem -Path $prefixDir.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^\d+$') {
          $xVal = [int]($_.Name)
          if ($xVal -ge $XMin -and $xVal -le $XMax) {
            $srcXDir = $_.FullName
            $dstXDir = Join-Path $RootPath $_.Name
            
            if (Test-Path $dstXDir) {
              # Merge into existing X directory
              Get-ChildItem -Path $srcXDir -File -Filter "*.png" -ErrorAction SilentlyContinue | ForEach-Object {
                $dstFile = Join-Path $dstXDir $_.Name
                if (-not (Test-Path $dstFile)) {
                  Move-Item -LiteralPath $_.FullName -Destination $dstFile -Force -ErrorAction SilentlyContinue
                }
              }
            } else {
              # Move entire X directory
              Move-Item -LiteralPath $srcXDir -Destination $dstXDir -Force -ErrorAction SilentlyContinue
            }
          }
        }
      }
      # Remove prefix directory if empty
      if (-not (Get-ChildItem -Path $prefixDir.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $prefixDir.FullName -Force -Recurse -ErrorAction SilentlyContinue
      }
    }
  }
}

# Extract specific X range from archive
function ExtractXRange {
  param(
    [string]$ArchivePath,
    [string]$OutDir,
    [int]$XMin,
    [int]$XMax,
    [int]$YMin,
    [int]$YMax,
    [bool]$Use7z,
    [string]$TempRoot
  )
  
  # Extract date from filename
  $dateMatch = [regex]::Match([System.IO.Path]::GetFileName($ArchivePath), '(\d{4}-\d{2}-\d{2})')
  if (-not $dateMatch.Success) {
    Log "[WARN] Could not extract date from: $(Split-Path -Leaf $ArchivePath)"
    return
  }
  
  $dateStr = $dateMatch.Groups[1].Value
  $finalDir = Join-Path $OutDir "tiles_$dateStr"
  
  # Check if this date already has tiles in the target X range
  $needsExtraction = $false
  for ($x = $XMin; $x -le $XMax; $x++) {
    $xDir = Join-Path $finalDir $x
    if (-not (Test-Path $xDir)) {
      $needsExtraction = $true
      break
    }
  }
  
  if (-not $needsExtraction) {
    Log "[SKIP] $dateStr - Already has tiles in X=$XMin-$XMax range"
    return
  }
  
  EnsureDir $finalDir
  
  Log "[EXTRACT] $dateStr (X=$XMin-$XMax, Y=$YMin-$YMax)"
  
  $tempDir = Join-Path $TempDir "extract_$dateStr"
  EnsureDir $tempDir
  
  try {
    if ($Use7z) {
      # Extract with 7z - extract full archive first, then filter
      & 7z x "$ArchivePath" -o"$tempDir" -y -bb0 -bd | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Log "[ERROR] 7z extraction failed for $dateStr"
        return
      }
    } else {
      # Extract with tar
      Push-Location $tempDir
      try {
        tar -xzf "$ArchivePath" 2>$null
        if ($LASTEXITCODE -ne 0) {
          Log "[ERROR] tar extraction failed for $dateStr"
          return
        }
      } finally {
        Pop-Location
      }
    }
    
    # Flatten structure and move relevant X directories
    FlattenToXY -RootPath $tempDir -XMin $XMin -XMax $XMax
    
    # Move extracted X directories to final location
    $moved = 0
    for ($x = $XMin; $x -le $XMax; $x++) {
      $srcXDir = Join-Path $tempDir $x
      if (Test-Path $srcXDir) {
        $dstXDir = Join-Path $finalDir $x
        if (Test-Path $dstXDir) {
          # Merge PNG files
          Get-ChildItem -Path $srcXDir -File -Filter "*.png" | ForEach-Object {
            $dstFile = Join-Path $dstXDir $_.Name
            if (-not (Test-Path $dstFile)) {
              Move-Item -LiteralPath $_.FullName -Destination $dstFile -Force
              $moved++
            }
          }
        } else {
          Move-Item -LiteralPath $srcXDir -Destination $dstXDir -Force
          $moved += (Get-ChildItem -Path $dstXDir -File -Filter "*.png" -Recurse | Measure-Object).Count
        }
      }
    }
    
    if ($moved -eq 0) {
      Log "[SKIP] $dateStr - No tiles found in X=$XMin-$XMax range"
      return
    }
    
    # Filter Y range
    FilterYRange -RootPath $finalDir -YMin $YMin -YMax $YMax
    
    # Count final tiles
    $count = 0
    for ($x = $XMin; $x -le $XMax; $x++) {
      $xDir = Join-Path $finalDir $x
      if (Test-Path $xDir) {
        $count += (Get-ChildItem -Path $xDir -File -Filter "*.png" | Measure-Object).Count
      }
    }
    
    Log "[DONE] $dateStr - $count new tiles extracted (X=$XMin-$XMax)"
    
  } finally {
    # Cleanup temp directory
    if (Test-Path $tempDir) {
      Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

# Main execution
Log "========================================="
Log "Extract Additional Tiles (Taif Region)"
Log "========================================="
Log "[CONFIG] Source: $TarGzDir"
Log "[CONFIG] Output: $TilesRoot"
Log "[CONFIG] Temp Dir: $TempDir"
Log "[CONFIG] X Range: $XMin-$XMax"
Log "[CONFIG] Y Range: $YMin-$YMax"
Log "[CONFIG] Parallel Jobs: $ParallelJobs"

# Ensure temp directory exists
EnsureDir $TempDir

# Verify source directory exists
if (-not (Test-Path $TarGzDir)) {
  Log "[ERROR] Source directory not found: $TarGzDir"
  exit 1
}

# Find all tar.gz files
$archives = Get-ChildItem -Path $TarGzDir -Filter "*.tar.gz" -File -ErrorAction SilentlyContinue | Sort-Object Name

if (-not $archives -or $archives.Count -eq 0) {
  Log "[ERROR] No .tar.gz files found in $TarGzDir"
  Log "[HINT] Looking for files like: 2025-10-22.tar.gz or archive_2025-10-22.tar.gz"
  exit 1
}

Log "[FOUND] $($archives.Count) archive(s)"

# Check PowerShell version for parallel support
$psVersion = $PSVersionTable.PSVersion.Major
if ($psVersion -lt 7) {
  Log "[WARN] PowerShell $psVersion detected. Parallel requires PS7+. Using sequential mode."
  $ParallelJobs = 1
}

# Process archives
$processed = 0
$startTime = Get-Date

if ($ParallelJobs -gt 1) {
  Log "[START] Processing with $ParallelJobs parallel jobs..."
  
  $archives | ForEach-Object -Parallel {
    $archive = $_
    $outDir = $using:TilesRoot
    $xMin = $using:XMin
    $xMax = $using:XMax
    $yMin = $using:YMin
    $yMax = $using:YMax
    $use7z = $using:use7z
    $tempRoot = $using:TempDir
    
    # Redefine functions in parallel scope
    function Log([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" }
    function EnsureDir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
    
    function FilterYRange {
      param([string]$RootPath, [int]$YMin, [int]$YMax)
      if (-not (Test-Path $RootPath)) { return }
      $removed = 0
      Get-ChildItem -Path $RootPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
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
      param([string]$RootPath, [int]$XMin, [int]$XMax)
      if (-not (Test-Path $RootPath)) { return }
      Get-ChildItem -Path $RootPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -notmatch '^\d+$') {
          $prefixDir = $_
          Get-ChildItem -Path $prefixDir.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match '^\d+$') {
              $xVal = [int]($_.Name)
              if ($xVal -ge $XMin -and $xVal -le $XMax) {
                $srcXDir = $_.FullName
                $dstXDir = Join-Path $RootPath $_.Name
                if (Test-Path $dstXDir) {
                  Get-ChildItem -Path $srcXDir -File -Filter "*.png" -ErrorAction SilentlyContinue | ForEach-Object {
                    $dstFile = Join-Path $dstXDir $_.Name
                    if (-not (Test-Path $dstFile)) {
                      Move-Item -LiteralPath $_.FullName -Destination $dstFile -Force -ErrorAction SilentlyContinue
                    }
                  }
                } else {
                  Move-Item -LiteralPath $srcXDir -Destination $dstXDir -Force -ErrorAction SilentlyContinue
                }
              }
            }
          }
          if (-not (Get-ChildItem -Path $prefixDir.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $prefixDir.FullName -Force -Recurse -ErrorAction SilentlyContinue
          }
        }
      }
    }
    
    function ExtractXRange {
      param([string]$ArchivePath, [string]$OutDir, [int]$XMin, [int]$XMax, [int]$YMin, [int]$YMax, [bool]$Use7z, [string]$TempRoot)
      $dateMatch = [regex]::Match([System.IO.Path]::GetFileName($ArchivePath), '(\d{4}-\d{2}-\d{2})')
      if (-not $dateMatch.Success) { Log "[WARN] Could not extract date from: $(Split-Path -Leaf $ArchivePath)"; return }
      $dateStr = $dateMatch.Groups[1].Value
      $finalDir = Join-Path $OutDir "tiles_$dateStr"
      $needsExtraction = $false
      for ($x = $XMin; $x -le $XMax; $x++) {
        if (-not (Test-Path (Join-Path $finalDir $x))) { $needsExtraction = $true; break }
      }
      if (-not $needsExtraction) { Log "[SKIP] $dateStr - Already has tiles in X=$XMin-$XMax range"; return }
      EnsureDir $finalDir
      Log "[EXTRACT] $dateStr (X=$XMin-$XMax, Y=$YMin-$YMax)"
      $tempDir = Join-Path $TempRoot "extract_$dateStr"
      EnsureDir $tempDir
      try {
        if ($Use7z) {
          & 7z x "$ArchivePath" -o"$tempDir" -y -bb0 -bd | Out-Null
          if ($LASTEXITCODE -ne 0) { Log "[ERROR] 7z extraction failed for $dateStr"; return }
        } else {
          Push-Location $tempDir
          try {
            tar -xzf "$ArchivePath" 2>$null
            if ($LASTEXITCODE -ne 0) { Log "[ERROR] tar extraction failed for $dateStr"; return }
          } finally { Pop-Location }
        }
        FlattenToXY -RootPath $tempDir -XMin $XMin -XMax $XMax
        $moved = 0
        for ($x = $XMin; $x -le $XMax; $x++) {
          $srcXDir = Join-Path $tempDir $x
          if (Test-Path $srcXDir) {
            $dstXDir = Join-Path $finalDir $x
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
              $movedCount = (Get-ChildItem -Path $dstXDir -File -Filter "*.png" -Recurse).Count
              $moved += $movedCount
            }
          }
        }
        FilterYRange -RootPath $finalDir -YMin $YMin -YMax $YMax
        $finalCount = (Get-ChildItem -Path $finalDir -File -Filter "*.png" -Recurse).Count
        Log "[DONE] $dateStr - Added $moved tiles (total: $finalCount in X=$XMin-$XMax)"
      } finally {
        if (Test-Path $tempDir) {
          Remove-Item -LiteralPath $tempDir -Force -Recurse -ErrorAction SilentlyContinue
        }
      }
    }
    
    ExtractXRange -ArchivePath $archive.FullName -OutDir $outDir `
                  -XMin $xMin -XMax $xMax -YMin $yMin -YMax $yMax -Use7z $use7z -TempRoot $tempRoot
  } -ThrottleLimit $ParallelJobs
  
  $processed = $archives.Count
  
} else {
  Log "[START] Processing sequentially..."
  
  foreach ($archive in $archives) {
    ExtractXRange -ArchivePath $archive.FullName -OutDir $TilesRoot `
                  -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax -Use7z $use7z -TempRoot $TempDir
    $processed++
  }
}

$elapsed = (Get-Date) - $startTime
Log "========================================="
Log "[COMPLETE] Processed $processed archive(s) in $($elapsed.TotalMinutes.ToString('F1')) minutes"
Log "========================================="
