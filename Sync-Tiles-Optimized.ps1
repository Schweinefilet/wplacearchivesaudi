# Sync-Tiles-Optimized.ps1
# Space-optimized version with streaming extraction and enhanced logging
param(
  [string]$Owner       = "murolem",
  [string]$Repo        = "wplace-archives",
  [string]$TilesRoot   = "tiles",  # Updated to relative path for Linux
  [string]$TempDir     = "/tmp/wplace-archive",  # Updated for Linux
  [datetime]$StartDate = (Get-Date -Year 2025 -Month 8 -Day 8).Date,  # First available date
  [datetime]$EndDate   = (Get-Date).Date,
  [int]$XMin = 1243,
  [int]$XMax = 1253,
  [int]$YMin = 875,
  [int]$YMax = 904,
  [int]$ParallelJobs = 2  # Reduced to limit disk usage
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Log([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor Cyan }
function LogSuccess([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor Green }
function LogWarn([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor Yellow }
function LogError([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor Red }
function EnsureDir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }

function UpdateSnapsJson {
  param([string]$TilesRoot, [string]$SnapsJsonPath = "snaps.json")
  
  Log "Updating snaps.json..."
  
  # Get all tiles_* directories
  $tileDirs = Get-ChildItem -Path $TilesRoot -Directory -Filter "tiles_*" | 
    Where-Object { $_.Name -match '^tiles_(\d{4}-\d{2}-\d{2})$' } |
    Sort-Object Name
  
  if ($tileDirs.Count -eq 0) {
    LogWarn "No tile directories found to add to snaps.json"
    return
  }
  
  # Build the JSON array
  $snaps = @()
  foreach ($dir in $tileDirs) {
    if ($dir.Name -match '^tiles_(.+)$') {
      $dateLabel = $Matches[1]
      $snaps += @{
        label = $dateLabel
        dir = "tiles/$($dir.Name)"
      }
    }
  }
  
  # Convert to JSON with proper formatting
  $jsonContent = ConvertTo-Json -InputObject $snaps -Depth 10
  
  # Write to file
  try {
    Set-Content -Path $SnapsJsonPath -Value $jsonContent -Encoding UTF8 -Force
    LogSuccess "✓ Updated snaps.json with $($snaps.Count) entries"
  } catch {
    LogError "Failed to update snaps.json: $($_.Exception.Message)"
  }
}

# Network tuning
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = 100
[Net.ServicePointManager]::Expect100Continue = $false
[Net.ServicePointManager]::UseNagleAlgorithm = $false
$ProgressPreference = 'SilentlyContinue'

# Check for tar (required for streaming)
$hasTar = (Get-Command "tar" -ErrorAction SilentlyContinue) -ne $null
if (-not $hasTar) {
  LogError "[ERROR] tar not found. This script requires tar for streaming extraction."
  exit 1
}
Log "Using tar for streaming extraction"

# Check for GitHub token
$token = $env:GITHUB_TOKEN
if ($token) { Log "Using GITHUB_TOKEN for API access" }
else { LogWarn "No GITHUB_TOKEN found. Rate limits may apply." }

EnsureDir $TilesRoot
EnsureDir $TempDir

Log "Region: X=$XMin-$XMax, Y=$YMin-$YMax (Mecca/Medina/Taif)"

# Functions
function GetMissingXFolders {
  param([string]$DateDir, [int]$XMin, [int]$XMax)
  $existing = @()
  $missing = @()
  
  for ($x = $XMin; $x -le $XMax; $x++) {
    $xDir = Join-Path $DateDir $x
    if (Test-Path $xDir) {
      $existing += $x
    } else {
      $missing += $x
    }
  }
  
  return @{
    Existing = $existing
    Missing = $missing
  }
}

function GetAllReleases {
  param([string]$Owner, [string]$Repo, [string]$Token)
  
  $allReleases = @()
  $page = 1
  $perPage = 100
  $headers = @{ 'Accept' = 'application/vnd.github.v3+json' }
  if ($Token) { $headers['Authorization'] = "token $Token" }
  
  do {
    $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases?per_page=$perPage&page=$page"
    try {
      $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing
      if ($releases.Count -eq 0) { break }
      $allReleases += $releases
      $page++
    } catch {
      LogError "Failed to fetch releases page $page : $($_.Exception.Message)"
      break
    }
  } while ($releases.Count -eq $perPage)
  
  return $allReleases
}

function CheckSnapshotPast9PM {
  param([string]$Date, [string]$Owner, [string]$Repo, [string]$Token)
  
  # Get releases for this date
  $releases = GetAllReleases -Owner $Owner -Repo $Repo -Token $Token
  $matchingReleases = $releases | Where-Object { $_.tag_name -match $Date }
  
  if ($matchingReleases.Count -eq 0) {
    return $false
  }
  
  # Check if any release has a timestamp past 9 PM (21:00)
  foreach ($release in $matchingReleases) {
    # Tag format is typically: YYYY-MM-DD_HH-MM-SS or similar
    if ($release.tag_name -match '(\d{2})-(\d{2})-(\d{2})') {
      $hour = [int]$Matches[1]
      if ($hour -ge 21) {
        return $true
      }
    }
  }
  
  return $false
}

function DownloadAsset {
  param([string]$Url, [string]$OutFile, [string]$Token)
  $headers = @{ 'Accept' = 'application/octet-stream' }
  if ($Token) { $headers['Authorization'] = "token $Token" }
  
  try {
    # For large files, show download progress
    $fileName = [System.IO.Path]::GetFileName($OutFile)
    
    $webClient = New-Object System.Net.WebClient
    foreach ($key in $headers.Keys) {
      $webClient.Headers.Add($key, $headers[$key])
    }
    
    # Register progress event with unique ID
    $progressId = 2
    $progressHandler = {
      param($sender, $e)
      if ($e.TotalBytesToReceive -gt 0) {
        $percentComplete = [math]::Round(($e.BytesReceived / $e.TotalBytesToReceive) * 100, 1)
        $receivedMB = [math]::Round($e.BytesReceived / 1MB, 2)
        $totalMB = [math]::Round($e.TotalBytesToReceive / 1MB, 2)
        
        Write-Progress -Id $using:progressId -Activity "Downloading $using:fileName" `
                       -Status "$receivedMB MB / $totalMB MB" `
                       -PercentComplete $percentComplete
      }
    }
    
    Register-ObjectEvent -InputObject $webClient -EventName DownloadProgressChanged -Action $progressHandler | Out-Null
    
    try {
      $webClient.DownloadFile($Url, $OutFile)
      Write-Progress -Id $progressId -Activity "Downloading $fileName" -Completed
      return $true
    } finally {
      Get-EventSubscriber | Where-Object { $_.SourceObject -eq $webClient } | Unregister-Event
      $webClient.Dispose()
    }
  } catch {
    Write-Progress -Id 2 -Activity "Downloading" -Completed
    LogError "Download failed: $($_.Exception.Message)"
    return $false
  }
}

function StreamExtractFiltered {
  param(
    [string]$ArchiveFile,
    [string]$OutputDir,
    [int]$XMin,
    [int]$XMax,
    [int]$YMin,
    [int]$YMax,
    [array]$OnlyX = $null  # If specified, only extract these X values
  )
  
  $filterFile = Join-Path $TempDir "filter_$(Get-Random).txt"
  
  try {
    Write-Progress -Id 3 -Activity "Scanning archive" -Status "Reading archive contents..." -PercentComplete 0
    Log "  Scanning archive contents..."
    $listing = & tar -tzf "$ArchiveFile" 2>$null
    
    Write-Progress -Id 3 -Activity "Filtering tiles" -Status "Filtering tiles for region..." -PercentComplete 30
    
    # Filter to only tiles in our region (and specific X folders if requested)
    $wanted = $listing | Where-Object {
      if ($_ -match '/(\d+)/(\d+)\.png$') {
        $x = [int]$Matches[1]
        $y = [int]$Matches[2]
        
        # Check Y range first
        if ($y -lt $YMin -or $y -gt $YMax) { return $false }
        
        # If OnlyX specified, check if this X is in the list
        if ($OnlyX -and $OnlyX.Count -gt 0) {
          return ($OnlyX -contains $x)
        }
        
        # Otherwise check X range
        return ($x -ge $XMin -and $x -le $XMax)
      }
      return $false
    }
    
    if ($wanted.Count -eq 0) {
      Write-Progress -Id 3 -Activity "Extracting tiles" -Completed
      LogWarn "  No matching tiles found in archive"
      return 0
    }
    
    # Write filter file
    Write-Progress -Id 3 -Activity "Preparing extraction" -Status "Creating filter list..." -PercentComplete 50
    $wanted | Set-Content -LiteralPath $filterFile -Encoding UTF8
    
    Log "  Extracting $($wanted.Count) tiles (filtered stream)..."
    Write-Progress -Id 3 -Activity "Extracting tiles" -Status "Extracting $($wanted.Count) tiles..." -PercentComplete 60
    
    # Extract only filtered files, stripping path components
    & tar -xzf "$ArchiveFile" -C "$OutputDir" --strip-components=1 -T "$filterFile" 2>$null
    
    Write-Progress -Id 3 -Activity "Extracting tiles" -Status "Completed extraction" -PercentComplete 100
    Start-Sleep -Milliseconds 200
    Write-Progress -Id 3 -Activity "Extracting tiles" -Completed
    
    return $wanted.Count
    
  } finally {
    if (Test-Path $filterFile) {
      Remove-Item -LiteralPath $filterFile -Force -ErrorAction SilentlyContinue
    }
  }
}

function ProcessDateOptimized {
  param(
    [string]$Date,
    [array]$MissingX,
    [array]$ExistingX,
    [string]$TilesRoot,
    [string]$TempDir,
    [int]$XMin,
    [int]$XMax,
    [int]$YMin,
    [int]$YMax,
    [string]$Token,
    [string]$Owner,
    [string]$Repo
  )
  
  $dateStr = $Date
  $finalDir = Join-Path $TilesRoot "tiles_$dateStr"
  
  # Flatten arrays
  $missingFlat = @()
  foreach ($m in $MissingX) {
    if ($m -is [System.Array]) { $missingFlat += $m }
    elseif ($null -ne $m -and $m -ne '') { $missingFlat += $m }
  }
  
  if ($missingFlat.Count -eq 0) {
    LogSuccess "[$dateStr] ✓ Complete (all X folders exist)"
    return
  }

  # Enhanced logging showing what's missing
  if ($ExistingX.Count -gt 0) {
    $existingStr = ($ExistingX | ForEach-Object { $_ }) -join ","
    $missingStr = ($missingFlat | ForEach-Object { $_ }) -join ","
    Log "[$dateStr] Existing: $existingStr | Missing: $missingStr"
  } else {
    Log "[$dateStr] Completely missing - downloading all X folders ($XMin-$XMax)"
  }
  
  # Find release
  $releases = GetAllReleases -Owner $Owner -Repo $Repo -Token $Token
  if ($releases.Count -eq 0) {
    LogError "  Could not fetch any releases"
    return
  }
  
  $matchingReleases = $releases | Where-Object { $_.tag_name -match $dateStr }
  if ($matchingReleases.Count -eq 0) {
    LogWarn "  No release found for $dateStr"
    return
  }
  
  $release = $matchingReleases | Sort-Object tag_name -Descending | Select-Object -First 1
  Log "  Found release: $($release.tag_name)"
  
  # Get archive assets
  $assets = $release.assets | Where-Object { $_.name -match '\.tar\.gz\.(aa|ab|ac|ad|ae|af|ag|ah|ai|aj|ak|al|am|an|ao|ap)$' }
  if ($assets.Count -eq 0) {
    $assets = $release.assets | Where-Object { $_.name -match '\.tar\.gz$' -and $_.name -notmatch '\.(aa|ab|ac)$' }
  }
  
  if ($assets.Count -eq 0) {
    LogWarn "  No archive assets found"
    return
  }
  
  # Use unique temp directory for this date
  $dateTempDir = Join-Path $TempDir "work_$dateStr"
  EnsureDir $dateTempDir
  EnsureDir $finalDir
  
  try {
    $archiveFile = $null
    
    # Download and join if needed
    if ($assets.Count -eq 1 -and $assets[0].name -match '\.tar\.gz$' -and $assets[0].name -notmatch '\.(aa|ab)$') {
      # Single complete archive
      $asset = $assets[0]
      $archiveFile = Join-Path $dateTempDir $asset.name
      
      Log "  Downloading: $($asset.name) ($([math]::Round($asset.size/1MB, 2)) MB)"
      if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $archiveFile -Token $Token)) {
        return
      }
      
    } elseif ($assets.Count -eq 1 -and $assets[0].name -match '\.tar\.gz\.aa$') {
      # Single .aa part
      $asset = $assets[0]
      $archiveFile = Join-Path $dateTempDir ($asset.name -replace '\.aa$', '')
      
      Log "  Downloading: $($asset.name) ($([math]::Round($asset.size/1MB, 2)) MB)"
      $tempPart = Join-Path $dateTempDir $asset.name
      if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $tempPart -Token $Token)) {
        return
      }
      Move-Item -LiteralPath $tempPart -Destination $archiveFile -Force
      
    } else {
      # Multi-part - download and join with immediate cleanup
      $baseName = ($assets[0].name -replace '\.(aa|ab|ac|ad|ae|af|ag|ah|ai|aj|ak|al|am|an|ao|ap)$', '')
      $archiveFile = Join-Path $dateTempDir $baseName
      
      Log "  Downloading and joining $($assets.Count) parts..."
      
      # Stream parts directly into joined file
      $outStream = [System.IO.File]::OpenWrite($archiveFile)
      try {
        $partIndex = 0
        foreach ($asset in ($assets | Sort-Object name)) {
          $partIndex++
          $partPercent = [math]::Round(($partIndex / $assets.Count) * 100, 1)
          
          Write-Progress -Id 4 -Activity "Joining multi-part archive" `
                         -Status "Part $partIndex of $($assets.Count): $($asset.name)" `
                         -PercentComplete $partPercent
          
          Log "    Part: $($asset.name) ($([math]::Round($asset.size/1MB, 2)) MB)"
          
          $tempPart = Join-Path $dateTempDir $asset.name
          if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $tempPart -Token $Token)) {
            throw "Failed to download $($asset.name)"
          }
          
          # Append to joined file and delete part immediately
          $inStream = [System.IO.File]::OpenRead($tempPart)
          try {
            $inStream.CopyTo($outStream)
          } finally {
            $inStream.Close()
          }
          
          Remove-Item -LiteralPath $tempPart -Force -ErrorAction SilentlyContinue
        }
        Write-Progress -Id 4 -Activity "Joining multi-part archive" -Completed
      } finally {
        $outStream.Close()
      }
      
      Log "  Joined archive: $([math]::Round((Get-Item $archiveFile).Length/1MB, 2)) MB"
    }
    
    # Extract ONLY the missing X folders using streaming
    $extracted = StreamExtractFiltered -ArchiveFile $archiveFile -OutputDir $dateTempDir `
                                       -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax `
                                       -OnlyX $missingFlat
    
    # Delete archive immediately after extraction
    Remove-Item -LiteralPath $archiveFile -Force -ErrorAction SilentlyContinue
    
    if ($extracted -eq 0) {
      LogWarn "  No tiles extracted"
      return
    }
    
    # Move extracted tiles to final location
    Write-Progress -Id 5 -Activity "Moving tiles to final location" -Status "Starting..." -PercentComplete 0
    $moved = 0
    $xIndex = 0
    foreach ($x in $missingFlat) {
      if ([string]::IsNullOrEmpty($x)) { continue }
      
      $xIndex++
      $xPercent = [math]::Round(($xIndex / $missingFlat.Count) * 100, 1)
      Write-Progress -Id 5 -Activity "Moving tiles to final location" `
                     -Status "Processing X=$x ($xIndex/$($missingFlat.Count))" `
                     -PercentComplete $xPercent
      
      $srcXDir = Join-Path $dateTempDir ([string]$x)
      if (Test-Path $srcXDir) {
        $dstXDir = Join-Path $finalDir ([string]$x)
        
        if (Test-Path $dstXDir) {
          # Merge (shouldn't happen but handle it)
          Get-ChildItem -Path $srcXDir -File -Filter "*.png" -ErrorAction SilentlyContinue | ForEach-Object {
            $dstFile = Join-Path $dstXDir $_.Name
            if (-not (Test-Path $dstFile)) {
              Move-Item -LiteralPath $_.FullName -Destination $dstFile -Force
              $moved++
            }
          }
        } else {
          # Move entire folder
          Move-Item -LiteralPath $srcXDir -Destination $dstXDir -Force
          $movedCount = (Get-ChildItem -Path $dstXDir -File -Filter "*.png" -Recurse -ErrorAction SilentlyContinue).Count
          $moved += $movedCount
        }
      } else {
        LogWarn "  X=$x not found in archive"
      }
    }
    
    Write-Progress -Id 5 -Activity "Moving tiles to final location" -Completed
    
    $finalCount = (Get-ChildItem -Path $finalDir -File -Filter "*.png" -Recurse -ErrorAction SilentlyContinue).Count
    LogSuccess "  ✓ Added $moved tiles | Total: $finalCount tiles"
    
  } finally {
    # Clean up all temp files for this date
    if (Test-Path $dateTempDir) {
      Remove-Item -LiteralPath $dateTempDir -Force -Recurse -ErrorAction SilentlyContinue
    }
  }
}

# Main execution
Write-Host "`n=========================================" -ForegroundColor Magenta
Write-Host "  Tile Sync - Space-Optimized Version" -ForegroundColor Magenta
Write-Host "=========================================`n" -ForegroundColor Magenta

# Check if today's date should be excluded (no snapshot past 9 PM)
$todayStr = (Get-Date).ToString('yyyy-MM-dd')
$shouldSkipToday = $false

if ($EndDate.Date -eq (Get-Date).Date) {
  Log "Checking if today ($todayStr) has a snapshot past 9 PM..."
  if (-not (CheckSnapshotPast9PM -Date $todayStr -Owner $Owner -Repo $Repo -Token $token)) {
    LogWarn "No snapshot past 9 PM found for today. Skipping $todayStr"
    $shouldSkipToday = $true
    $EndDate = $EndDate.AddDays(-1)
  } else {
    LogSuccess "Snapshot past 9 PM found for today. Including $todayStr"
  }
}

# Scan existing tiles
$allDates = @()
for ($d = $StartDate; $d -le $EndDate; $d = $d.AddDays(1)) {
  $dateStr = $d.ToString('yyyy-MM-dd')
  $dateDir = Join-Path $TilesRoot "tiles_$dateStr"
  
  if (Test-Path $dateDir) {
    $status = GetMissingXFolders -DateDir $dateDir -XMin $XMin -XMax $XMax
    if ($status.Missing.Count -gt 0) {
      $allDates += @{
        Date = $dateStr
        MissingX = $status.Missing
        ExistingX = $status.Existing
      }
    }
  } else {
    # Entire date missing
    $allDates += @{
      Date = $dateStr
      MissingX = @($XMin..$XMax)
      ExistingX = @()
    }
  }
}

if ($allDates.Count -eq 0) {
  LogSuccess "✓ All dates are complete! Nothing to do."
  exit 0
}

Log "Found $($allDates.Count) dates needing work"
Log "Max parallel jobs: $ParallelJobs (to limit disk usage)"
Write-Host ""

# Initialize progress tracking
$script:processedCount = 0
$script:totalCount = $allDates.Count
$script:lockObject = [System.Object]::new()

function UpdateProgress {
  param([string]$DateStr, [string]$Status)
  
  $script:processedCount++
  $percentComplete = [math]::Round(($script:processedCount / $script:totalCount) * 100, 1)
  
  Write-Progress -Activity "Syncing Tiles" `
                 -Status "$Status - $DateStr ($script:processedCount/$script:totalCount)" `
                 -PercentComplete $percentComplete
}

# Process dates with limited parallelism
if ($ParallelJobs -gt 1) {
  $allDates | ForEach-Object -Parallel {
    $dateInfo = $_
    $tilesRoot = $using:TilesRoot
    $tempDir = $using:TempDir
    $xMin = $using:XMin
    $xMax = $using:XMax
    $yMin = $using:YMin
    $yMax = $using:YMax
    $token = $using:token
    $owner = $using:Owner
    $repo = $using:Repo
    $lockObject = $using:lockObject
    $totalCount = $using:totalCount
    
    # Redefine functions in parallel scope
    function Log([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor Cyan }
    function LogSuccess([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor Green }
    function LogWarn([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor Yellow }
    function LogError([string]$m){ Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $m" -ForegroundColor Red }
    function EnsureDir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
    
    function UpdateProgressParallel {
      param([string]$DateStr, [string]$Status)
      
      # Thread-safe progress update
      [System.Threading.Monitor]::Enter($lockObject)
      try {
        $script:processedCount = if ($null -eq $script:processedCount) { 1 } else { $script:processedCount + 1 }
        $percentComplete = [math]::Round(($script:processedCount / $totalCount) * 100, 1)
        
        Write-Progress -Activity "Syncing Tiles" `
                       -Status "$Status - $DateStr ($script:processedCount/$totalCount)" `
                       -PercentComplete $percentComplete
      } finally {
        [System.Threading.Monitor]::Exit($lockObject)
      }
    }
    
    function GetAllReleasesLocal {
      param([string]$Owner, [string]$Repo, [string]$Token)
      $allReleases = @()
      $page = 1
      $perPage = 100
      $headers = @{ 'Accept' = 'application/vnd.github.v3+json' }
      if ($Token) { $headers['Authorization'] = "token $Token" }
      
      do {
        $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases?per_page=$perPage&page=$page"
        try {
          $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing
          if ($releases.Count -eq 0) { break }
          $allReleases += $releases
          $page++
        } catch { break }
      } while ($releases.Count -eq $perPage)
      
      return $allReleases
    }
    
    function DownloadAsset {
      param([string]$Url, [string]$OutFile, [string]$Token)
      $headers = @{ 'Accept' = 'application/octet-stream' }
      if ($Token) { $headers['Authorization'] = "token $Token" }
      
      try {
        $fileName = [System.IO.Path]::GetFileName($OutFile)
        
        $webClient = New-Object System.Net.WebClient
        foreach ($key in $headers.Keys) {
          $webClient.Headers.Add($key, $headers[$key])
        }
        
        # Register progress event for parallel downloads
        $progressHandler = {
          param($sender, $e)
          if ($e.TotalBytesToReceive -gt 0) {
            $percentComplete = [math]::Round(($e.BytesReceived / $e.TotalBytesToReceive) * 100, 1)
            $receivedMB = [math]::Round($e.BytesReceived / 1MB, 2)
            $totalMB = [math]::Round($e.TotalBytesToReceive / 1MB, 2)
            
            Write-Progress -Id 1 -Activity "Downloading $fileName" `
                           -Status "$receivedMB MB / $totalMB MB" `
                           -PercentComplete $percentComplete
          }
        }
        
        Register-ObjectEvent -InputObject $webClient -EventName DownloadProgressChanged -Action $progressHandler | Out-Null
        
        try {
          $webClient.DownloadFile($Url, $OutFile)
          Write-Progress -Id 1 -Activity "Downloading $fileName" -Completed
          return $true
        } finally {
          Get-EventSubscriber | Where-Object { $_.SourceObject -eq $webClient } | Unregister-Event
          $webClient.Dispose()
        }
      } catch {
        Write-Progress -Id 1 -Activity "Downloading" -Completed
        LogError "Download failed: $($_.Exception.Message)"
        return $false
      }
    }
    
    function StreamExtractFilteredLocal {
      param([string]$ArchiveFile, [string]$OutputDir, [int]$XMin, [int]$XMax, [int]$YMin, [int]$YMax, [array]$OnlyX = $null)
      
      $filterFile = Join-Path $tempDir "filter_$(Get-Random).txt"
      try {
        Write-Progress -Id 3 -Activity "Scanning archive" -Status "Reading archive contents..." -PercentComplete 0
        Log "  Scanning archive..."
        $listing = & tar -tzf "$ArchiveFile" 2>$null
        
        Write-Progress -Id 3 -Activity "Filtering tiles" -Status "Filtering tiles for region..." -PercentComplete 30
        
        $wanted = $listing | Where-Object {
          if ($_ -match '/(\d+)/(\d+)\.png$') {
            $x = [int]$Matches[1]
            $y = [int]$Matches[2]
            if ($y -lt $YMin -or $y -gt $YMax) { return $false }
            if ($OnlyX -and $OnlyX.Count -gt 0) { return ($OnlyX -contains $x) }
            return ($x -ge $XMin -and $x -le $XMax)
          }
          return $false
        }
        
        if ($wanted.Count -eq 0) {
          Write-Progress -Id 3 -Activity "Extracting tiles" -Completed
          return 0
        }
        
        Write-Progress -Id 3 -Activity "Preparing extraction" -Status "Creating filter list..." -PercentComplete 50
        $wanted | Set-Content -LiteralPath $filterFile -Encoding UTF8
        Log "  Extracting $($wanted.Count) tiles..."
        Write-Progress -Id 3 -Activity "Extracting tiles" -Status "Extracting $($wanted.Count) tiles..." -PercentComplete 60
        & tar -xzf "$ArchiveFile" -C "$OutputDir" --strip-components=1 -T "$filterFile" 2>$null
        
        Write-Progress -Id 3 -Activity "Extracting tiles" -Status "Completed extraction" -PercentComplete 100
        Start-Sleep -Milliseconds 200
        Write-Progress -Id 3 -Activity "Extracting tiles" -Completed
        
        return $wanted.Count
      } finally {
        if (Test-Path $filterFile) {
          Remove-Item -LiteralPath $filterFile -Force -ErrorAction SilentlyContinue
        }
      }
    }
    
    # Process this date
    $dateStr = $dateInfo.Date
    $missingX = $dateInfo.MissingX
    $existingX = $dateInfo.ExistingX
    $finalDir = Join-Path $tilesRoot "tiles_$dateStr"
    
    $missingFlat = @()
    foreach ($m in $missingX) {
      if ($m -is [System.Array]) { $missingFlat += $m }
      elseif ($null -ne $m -and $m -ne '') { $missingFlat += $m }
    }
    
    if ($missingFlat.Count -eq 0) { 
      LogSuccess "[$dateStr] ✓ Complete"
      UpdateProgressParallel -DateStr $dateStr -Status "Skipped (complete)"
      return
    }

    if ($existingX.Count -gt 0) {
      $existingStr = ($existingX | ForEach-Object { $_ }) -join ","
      $missingStr = ($missingFlat | ForEach-Object { $_ }) -join ","
      Log "[$dateStr] Existing: $existingStr | Missing: $missingStr"
    } else {
      Log "[$dateStr] Downloading all X folders ($xMin-$xMax)"
    }
    
    UpdateProgressParallel -DateStr $dateStr -Status "Processing"
    
    $releases = GetAllReleasesLocal -Owner $owner -Repo $repo -Token $token
    if ($releases.Count -eq 0) { return }
    
    $matchingReleases = $releases | Where-Object { $_.tag_name -match $dateStr }
    if ($matchingReleases.Count -eq 0) { return }
    
    $release = $matchingReleases | Sort-Object tag_name -Descending | Select-Object -First 1
    Log "  Found: $($release.tag_name)"
    
    $assets = $release.assets | Where-Object { $_.name -match '\.tar\.gz\.(aa|ab|ac|ad|ae|af|ag|ah|ai|aj|ak|al|am|an|ao|ap)$' }
    if ($assets.Count -eq 0) {
      $assets = $release.assets | Where-Object { $_.name -match '\.tar\.gz$' -and $_.name -notmatch '\.(aa|ab|ac)$' }
    }
    if ($assets.Count -eq 0) { return }
    
    $dateTempDir = Join-Path $tempDir "work_$dateStr"
    EnsureDir $dateTempDir
    EnsureDir $finalDir
    
    try {
      $archiveFile = $null
      
      if ($assets.Count -eq 1 -and $assets[0].name -match '\.tar\.gz$' -and $assets[0].name -notmatch '\.(aa|ab)$') {
        $asset = $assets[0]
        $archiveFile = Join-Path $dateTempDir $asset.name
        Log "  Downloading: $($asset.name)"
        if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $archiveFile -Token $token)) { return }
        
      } elseif ($assets.Count -eq 1 -and $assets[0].name -match '\.tar\.gz\.aa$') {
        $asset = $assets[0]
        $archiveFile = Join-Path $dateTempDir ($asset.name -replace '\.aa$', '')
        Log "  Downloading: $($asset.name)"
        $tempPart = Join-Path $dateTempDir $asset.name
        if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $tempPart -Token $token)) { return }
        Move-Item -LiteralPath $tempPart -Destination $archiveFile -Force
        
      } else {
        $baseName = ($assets[0].name -replace '\.(aa|ab|ac|ad|ae|af|ag|ah|ai|aj|ak|al|am|an|ao|ap)$', '')
        $archiveFile = Join-Path $dateTempDir $baseName
        Log "  Joining $($assets.Count) parts..."
        
        $outStream = [System.IO.File]::OpenWrite($archiveFile)
        try {
          $partIndex = 0
          foreach ($asset in ($assets | Sort-Object name)) {
            $partIndex++
            $partPercent = [math]::Round(($partIndex / $assets.Count) * 100, 1)
            
            Write-Progress -Id 4 -Activity "Joining multi-part archive" `
                           -Status "Part $partIndex of $($assets.Count): $($asset.name)" `
                           -PercentComplete $partPercent
            
            $tempPart = Join-Path $dateTempDir $asset.name
            if (-not (DownloadAsset -Url $asset.browser_download_url -OutFile $tempPart -Token $token)) { throw "Failed" }
            
            $inStream = [System.IO.File]::OpenRead($tempPart)
            try { $inStream.CopyTo($outStream) } finally { $inStream.Close() }
            Remove-Item -LiteralPath $tempPart -Force -ErrorAction SilentlyContinue
          }
          Write-Progress -Id 4 -Activity "Joining multi-part archive" -Completed
        } finally { $outStream.Close() }
      }
      
      $extracted = StreamExtractFilteredLocal -ArchiveFile $archiveFile -OutputDir $dateTempDir `
                                              -XMin $xMin -XMax $xMax -YMin $yMin -YMax $yMax `
                                              -OnlyX $missingFlat
      Remove-Item -LiteralPath $archiveFile -Force -ErrorAction SilentlyContinue
      
      if ($extracted -eq 0) { return }
      
      Write-Progress -Id 5 -Activity "Moving tiles to final location" -Status "Starting..." -PercentComplete 0
      $moved = 0
      $xIndex = 0
      foreach ($x in $missingFlat) {
        if ([string]::IsNullOrEmpty($x)) { continue }
        
        $xIndex++
        $xPercent = [math]::Round(($xIndex / $missingFlat.Count) * 100, 1)
        Write-Progress -Id 5 -Activity "Moving tiles to final location" `
                       -Status "Processing X=$x ($xIndex/$($missingFlat.Count))" `
                       -PercentComplete $xPercent
        
        $srcXDir = Join-Path $dateTempDir ([string]$x)
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
            $movedCount = (Get-ChildItem -Path $dstXDir -File -Filter "*.png" -Recurse).Count
            $moved += $movedCount
          }
        }
      }
      
      Write-Progress -Id 5 -Activity "Moving tiles to final location" -Completed
      
      $finalCount = (Get-ChildItem -Path $finalDir -File -Filter "*.png" -Recurse).Count
      LogSuccess "  ✓ Added $moved tiles | Total: $finalCount tiles"
      UpdateProgressParallel -DateStr $dateStr -Status "Completed"
      
    } finally {
      if (Test-Path $dateTempDir) {
        Remove-Item -LiteralPath $dateTempDir -Force -Recurse -ErrorAction SilentlyContinue
      }
    }
  } -ThrottleLimit $ParallelJobs
  
  # Clear progress bar after completion
  Write-Progress -Activity "Syncing Tiles" -Completed
  
} else {
  Log "Processing sequentially..."
  
  $currentIndex = 0
  foreach ($dateInfo in $allDates) {
    $currentIndex++
    $percentComplete = [math]::Round(($currentIndex / $allDates.Count) * 100, 1)
    
    Write-Progress -Activity "Syncing Tiles" `
                   -Status "Processing $($dateInfo.Date) ($currentIndex/$($allDates.Count))" `
                   -PercentComplete $percentComplete
    
    ProcessDateOptimized -Date $dateInfo.Date -MissingX $dateInfo.MissingX -ExistingX $dateInfo.ExistingX `
                         -TilesRoot $TilesRoot -TempDir $TempDir `
                         -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax `
                         -Token $token -Owner $Owner -Repo $Repo
  }
  
  # Clear progress bar after completion
  Write-Progress -Activity "Syncing Tiles" -Completed
}

Write-Host "`n" -NoNewline
LogSuccess "✓ All dates processed!"

# Update snaps.json with all tile directories
UpdateSnapsJson -TilesRoot $TilesRoot -SnapsJsonPath "snaps.json"

Write-Host ""
