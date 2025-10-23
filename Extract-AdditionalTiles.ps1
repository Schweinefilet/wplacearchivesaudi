# Extract-AdditionalTiles.ps1
# Extracts missing X coordinates (1251-1253) from existing tar.gz files
param(
  [string]$TarGzDir    = "E:\Downloads E",
  [string]$TilesRoot   = "E:\wplace-site\tiles",
  [int]$XMin = 1251,
  [int]$XMax = 1253,
  [int]$YMin = 875,
  [int]$YMax = 904,
  [int]$ParallelJobs = 3
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Log([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" }
function Ensure-Dir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }

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

# Check for 7z (preferred) or tar
$use7z = (Get-Command "7z" -ErrorAction SilentlyContinue) -ne $null
if ($use7z) {
  Log "[INFO] Using 7z for extraction (faster)"
} else {
  if (-not (Get-Command "tar" -ErrorAction SilentlyContinue)) {
    Log "[ERROR] Neither 7z nor tar found. Install one of them."
    exit 1
  }
  Log "[INFO] Using tar for extraction"
}

# Filter function to keep only Y range
function Filter-YRange {
  param([string]$Path, [int]$YMin, [int]$YMax)
  
  if (-not (Test-Path $Path)) { return }
  
  $removed = 0
  Get-ChildItem -Path $Path -Directory | ForEach-Object {
    $xDir = $_
    Get-ChildItem -Path $xDir.FullName -File -Filter "*.png" | ForEach-Object {
      $yVal = [int]($_.BaseName)
      if ($yVal -lt $YMin -or $yVal -gt $YMax) {
        Remove-Item -LiteralPath $_.FullName -Force
        $removed++
      }
    }
    # Remove empty X directories
    if (-not (Get-ChildItem -Path $xDir.FullName -File)) {
      Remove-Item -LiteralPath $xDir.FullName -Force -Recurse
    }
  }
  
  if ($removed -gt 0) {
    Log "[FILTER] Removed $removed tiles outside Y range ($YMin-$YMax)"
  }
}

# Extract specific X range from archive
function Extract-XRange {
  param(
    [string]$ArchivePath,
    [string]$OutDir,
    [int]$XMin,
    [int]$XMax,
    [int]$YMin,
    [int]$YMax,
    [bool]$Use7z
  )
  
  $dateMatch = [regex]::Match([System.IO.Path]::GetFileName($ArchivePath), '(\d{4}-\d{2}-\d{2})')
  if (-not $dateMatch.Success) {
    Log "[WARN] Could not extract date from $ArchivePath"
    return
  }
  
  $dateStr = $dateMatch.Groups[1].Value
  $finalDir = Join-Path $OutDir "tiles_$dateStr"
  
  Ensure-Dir $finalDir
  
  Log "[EXTRACT] $dateStr from $(Split-Path -Leaf $ArchivePath)"
  
  if ($Use7z) {
    # Extract only the X range we need
    for ($x = $XMin; $x -le $XMax; $x++) {
      $pattern = "$x/*"
      try {
        & 7z x "$ArchivePath" -o"$finalDir" "$pattern" -y -bb0 -bd | Out-Null
      } catch {
        # Ignore if X coordinate doesn't exist in archive
      }
    }
  } else {
    # tar extraction
    $tempList = Join-Path $env:TEMP "tarlist_$dateStr.txt"
    try {
      tar -tzf "$ArchivePath" > "$tempList" 2>$null
      
      # Filter for X range
      $filtered = Get-Content $tempList | Where-Object {
        if ($_ -match '(\d{4})/') {
          $xVal = [int]$matches[1]
          return ($xVal -ge $XMin -and $xVal -le $XMax)
        }
        return $false
      }
      
      if ($filtered) {
        $filtered | tar -xzf "$ArchivePath" -C "$finalDir" --files-from - 2>$null
      }
    } finally {
      if (Test-Path $tempList) { Remove-Item $tempList -Force }
    }
  }
  
  # Filter Y range
  Filter-YRange -Path $finalDir -YMin $YMin -YMax $YMax
  
  # Count extracted tiles
  $count = (Get-ChildItem -Path $finalDir -Recurse -File -Filter "*.png" -ErrorAction SilentlyContinue | Measure-Object).Count
  if ($count -gt 0) {
    Log "[DONE] $dateStr - $count tiles extracted"
  } else {
    Log "[SKIP] $dateStr - No tiles in X range $XMin-$XMax"
    if (Test-Path $finalDir) { Remove-Item $finalDir -Recurse -Force }
  }
}

# Main execution
Log "========================================="
Log "Extract Additional Tiles for Taif"
Log "========================================="
Log "[CONFIG] Source: $TarGzDir"
Log "[CONFIG] Output: $TilesRoot"
Log "[CONFIG] X Range: $XMin-$XMax (Taif region)"
Log "[CONFIG] Y Range: $YMin-$YMax"
Log "[CONFIG] Parallel Jobs: $ParallelJobs"

# Find all tar.gz files
$archives = Get-ChildItem -Path $TarGzDir -Filter "*.tar.gz" | Sort-Object Name

if (-not $archives) {
  Log "[ERROR] No .tar.gz files found in $TarGzDir"
  exit 1
}

Log "[FOUND] $($archives.Count) .tar.gz files"

# Check PowerShell version for parallel support
$psVersion = $PSVersionTable.PSVersion.Major
if ($psVersion -lt 7) {
  Log "[WARN] PowerShell $psVersion detected. Parallel processing requires PS7+, using sequential mode."
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
    
    # Re-define functions in parallel scope
    function Log([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" }
    function Ensure-Dir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
    
    function Filter-YRange {
      param([string]$Path, [int]$YMin, [int]$YMax)
      if (-not (Test-Path $Path)) { return }
      $removed = 0
      Get-ChildItem -Path $Path -Directory | ForEach-Object {
        $xDir = $_
        Get-ChildItem -Path $xDir.FullName -File -Filter "*.png" | ForEach-Object {
          $yVal = [int]($_.BaseName)
          if ($yVal -lt $YMin -or $yVal -gt $YMax) {
            Remove-Item -LiteralPath $_.FullName -Force
            $removed++
          }
        }
        if (-not (Get-ChildItem -Path $xDir.FullName -File)) {
          Remove-Item -LiteralPath $xDir.FullName -Force -Recurse
        }
      }
      if ($removed -gt 0) {
        Log "[FILTER] Removed $removed tiles outside Y range ($YMin-$YMax)"
      }
    }
    
    function Extract-XRange {
      param(
        [string]$ArchivePath, [string]$OutDir, [int]$XMin, [int]$XMax,
        [int]$YMin, [int]$YMax, [bool]$Use7z
      )
      
      $dateMatch = [regex]::Match([System.IO.Path]::GetFileName($ArchivePath), '(\d{4}-\d{2}-\d{2})')
      if (-not $dateMatch.Success) { return }
      
      $dateStr = $dateMatch.Groups[1].Value
      $finalDir = Join-Path $OutDir "tiles_$dateStr"
      
      Ensure-Dir $finalDir
      Log "[EXTRACT] $dateStr from $(Split-Path -Leaf $ArchivePath)"
      
      if ($Use7z) {
        for ($x = $XMin; $x -le $XMax; $x++) {
          try {
            & 7z x "$ArchivePath" -o"$finalDir" "$x/*" -y -bb0 -bd | Out-Null
          } catch {}
        }
      } else {
        $tempList = Join-Path $env:TEMP "tarlist_$dateStr.txt"
        try {
          tar -tzf "$ArchivePath" > "$tempList" 2>$null
          $filtered = Get-Content $tempList | Where-Object {
            if ($_ -match '(\d{4})/') {
              $xVal = [int]$matches[1]
              return ($xVal -ge $XMin -and $xVal -le $XMax)
            }
            return $false
          }
          if ($filtered) {
            $filtered | tar -xzf "$ArchivePath" -C "$finalDir" --files-from - 2>$null
          }
        } finally {
          if (Test-Path $tempList) { Remove-Item $tempList -Force }
        }
      }
      
      Filter-YRange -Path $finalDir -YMin $YMin -YMax $YMax
      
      $count = (Get-ChildItem -Path $finalDir -Recurse -File -Filter "*.png" -ErrorAction SilentlyContinue | Measure-Object).Count
      if ($count -gt 0) {
        Log "[DONE] $dateStr - $count tiles extracted"
      } else {
        if (Test-Path $finalDir) { Remove-Item $finalDir -Recurse -Force }
      }
    }
    
    Extract-XRange -ArchivePath $archive.FullName -OutDir $outDir `
                   -XMin $xMin -XMax $xMax -YMin $yMin -YMax $yMax -Use7z $use7z
  } -ThrottleLimit $ParallelJobs
  
  $processed = $archives.Count
  
} else {
  Log "[START] Processing sequentially..."
  
  foreach ($archive in $archives) {
    Extract-XRange -ArchivePath $archive.FullName -OutDir $TilesRoot `
                   -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax -Use7z $use7z
    $processed++
  }
}

$elapsed = (Get-Date) - $startTime
Log "========================================="
Log "[COMPLETE] Processed $processed archives in $($elapsed.TotalMinutes.ToString('F1')) minutes"
Log "========================================="
