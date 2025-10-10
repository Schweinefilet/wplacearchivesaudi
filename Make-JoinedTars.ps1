# Make-JoinedTars.ps1 — JOIN+EXTRACT with FORCE on invalid tars (resume-safe)
# Window: 2025-08-09 .. 2025-08-20
# Roots scanned: E:\Downloads E
# Output: E:\wplace-archive\archive_YYYY-MM-DD.tar.gz and tiles_YYYY-MM-DD\{x}\{y}.png

# ================== CONFIG ==================
$ROOTS    = @("E:\Downloads E")         # where .tar.gz or split parts live
$OUT_DIR  = "E:\wplace-archive"         # where archive_*.tar.gz and tiles_* go
$OUT_ARCH = $OUT_DIR                    # archives live here

# z=11 box (Mecca/Medina/Jeddah/Taif rectangle)
$X_MIN=1243; $X_MAX=1258
$Y_MIN= 875; $Y_MAX= 904

# Cleanup toggles (only applied for clean OK extracts; partials keep artifacts)
$DELETE_SOURCES_AFTER_SUCCESS = $true
$DELETE_TAR_AFTER_EXTRACT     = $true

# FORCE extraction even when validation fails (best-effort, partial OK)
$FORCE_EXTRACT_ON_INVALID     = $true

# Date window (inclusive)
$START_DATE = [datetime]'2025-08-09'
$END_DATE   = [datetime]'2025-09-16'
# ============================================

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Test-TarOk([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $prev = $ErrorActionPreference
  try { $ErrorActionPreference = "Continue"; $null = & tar -tzf $Path 2>$null; return ($LASTEXITCODE -eq 0) }
  finally { $ErrorActionPreference = $prev }
}

function New-HardLinkOrCopy([string]$Src, [string]$Dst) {
  $dstDir = [System.IO.Path]::GetDirectoryName($Dst); if ([string]::IsNullOrWhiteSpace($dstDir)) { $dstDir = (Get-Location).Path }
  Ensure-Dir $dstDir
  $srcDrive = [System.IO.Path]::GetPathRoot($Src).TrimEnd('\').ToUpper()
  $dstDrive = [System.IO.Path]::GetPathRoot($Dst).TrimEnd('\').ToUpper()
  if ($srcDrive -eq $dstDrive) {
    try { New-Item -ItemType HardLink -Path $Dst -Target $Src -Force | Out-Null; return } catch { Copy-Item -LiteralPath $Src -Destination $Dst -Force }
  } else { Copy-Item -LiteralPath $Src -Destination $Dst -Force }
}

function Find-Prejoined([string]$Date) {
  if (-not $ROOTS) { return $null }
  $cands = Get-ChildItem -Path $ROOTS -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like "*$Date*.tar.gz" -and $_.Name -notmatch '\.tar\.gz\.(?:[a-z]{2}|\d{3})$' } |
           Sort-Object Length -Descending
  if ($cands) { return ($cands | Select-Object -First 1) }
  return $null
}

# Return: array of PSCustomObjects with Stem, Parts[], Count, TotalBytes
function Get-PartGroups([string]$Date) {
  if (-not $ROOTS) { return @() }
  $all = Get-ChildItem -Path $ROOTS -Recurse -File -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -like "*$Date*.tar.gz.*" }
  if (-not $all) { return @() }

  $groups = $all | Group-Object { $_.FullName -replace '\.([a-z]{2}|\d{3})$','' }
  $out = @()
  foreach ($g in $groups) {
    $ordered = $g.Group | Sort-Object Name
    $out += [pscustomobject]@{
      Stem       = $g.Name
      Parts      = $ordered
      Count      = @($ordered).Count
      TotalBytes = ($ordered | Measure-Object Length -Sum).Sum
    }
  }
  $out | Sort-Object @{Expression='Count';Descending=$true}, @{Expression='TotalBytes';Descending=$true}
}

function Show-PartDiagnostics([string]$Date) {
  $groups = @(Get-PartGroups $Date)
  if (-not $groups -or @($groups).Count -eq 0) { Write-Host "[MISS] $Date no parts."; return }
  foreach ($g in $groups) {
    Write-Host ("[CAND] {0} parts={1} total={2:N2} GB stem=`"{3}`"" -f $Date, $g.Count, ($g.TotalBytes/1GB), $g.Stem)
    foreach ($p in ($g.Parts | Sort-Object Name)) {
      Write-Host ("{0,12:N0}  {1}" -f $p.Length, $p.FullName)
    }
  }
}

function Join-Parts-Resumable([System.IO.FileInfo[]]$Parts, [string]$OutPath, [string]$Date) {
  $outDir = [System.IO.Path]::GetDirectoryName($OutPath); Ensure-Dir $outDir
  $tmp = "$OutPath.partial"
  $total = ($Parts | Measure-Object Length -Sum).Sum
  if (-not $total) { throw "No parts to join for $Date" }

  $written = 0L
  if (Test-Path -LiteralPath $tmp) { $written = (Get-Item -LiteralPath $tmp).Length }
  elseif (Test-Path -LiteralPath $OutPath) {
    if (Test-TarOk $OutPath) { return $OutPath }
    Remove-Item -LiteralPath $OutPath -Force -ErrorAction SilentlyContinue
  }

  $bufSize = 16MB
  $id = 7100
  $mode = ([System.IO.FileMode]::Create)
  if ($written -gt 0) { $mode = [System.IO.FileMode]::Append }

  $out = [System.IO.File]::Open($tmp, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try {
    $skip = $written
    $done = $written
    $buf  = New-Object byte[] $bufSize
    $k = 0
    foreach ($part in $Parts) {
      $k++
      $partSkip = 0L
      if ($skip -gt 0) {
        if ($skip -ge $part.Length) { $skip -= $part.Length; continue }
        $partSkip = $skip; $skip = 0
      }
      $in = [System.IO.File]::OpenRead($part.FullName)
      try {
        if ($partSkip -gt 0) { $in.Seek($partSkip, [System.IO.SeekOrigin]::Begin) | Out-Null }
        while ($true) {
          $read = $in.Read($buf, 0, $buf.Length)
          if ($read -le 0) { break }
          $out.Write($buf, 0, $read)
          $done += $read
          $pct = [int](100.0 * $done / $total)
          Write-Progress -Id $id -Activity "Joining $Date" -Status "$k / $(@($Parts).Count): $($part.Name)" -PercentComplete $pct
        }
      } finally { $in.Dispose() }
    }
  } finally {
    $out.Dispose()
    Write-Progress -Id $id -Completed -Activity "Joining $Date"
  }

  if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force -ErrorAction SilentlyContinue }
  Rename-Item -LiteralPath $tmp -NewName ([System.IO.Path]::GetFileName($OutPath))
  return $OutPath
}

function Ensure-Joined([string]$Date, [ref]$UsedSources) {
  $dst = Join-Path $OUT_ARCH "archive_$Date.tar.gz"

  if (Test-Path -LiteralPath $dst) {
    if (Test-TarOk $dst) { Write-Host "[SKIP] $Date already OK -> $dst"; return $dst }
    Write-Host "[WARN] $Date target exists but fails verify, rebuilding -> $dst"
    Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
  }

  $pre = Find-Prejoined $Date
  if ($pre) {
    Write-Host "[LINK] $Date using prejoined: $($pre.FullName)"
    New-HardLinkOrCopy -Src $pre.FullName -Dst $dst
    if (Test-TarOk $dst) { $UsedSources.Value = @($pre.FullName); Write-Host "[OK]   $Date verified."; return $dst }
    Write-Host "[WARN] $Date prejoined failed verify; trying split sets anyway."
    # keep $dst for forced extraction too
  }

  # Try each candidate split stem
  $cands = @(Get-PartGroups $Date)
  if ((-not $cands -or @($cands).Count -eq 0) -and $pre) {
    if ($FORCE_EXTRACT_ON_INVALID) { return $dst }
    Write-Host "[MISS] $Date no parts found."; return $null
  } elseif (-not $cands -or @($cands).Count -eq 0) {
    Write-Host "[MISS] $Date no parts found."; return $null
  }

  foreach ($g in $cands) {
    $parts = @($g.Parts | Sort-Object Name)
    $partial = "$dst.partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $dst)      { Remove-Item -LiteralPath $dst      -Force -ErrorAction SilentlyContinue }

    if (@($parts).Count -eq 1) {
      $the = $parts[0]
      Write-Host "[ONE ] $Date one file: $($the.Name). Probing..."
      if (Test-TarOk $the.FullName) {
        New-HardLinkOrCopy -Src $the.FullName -Dst $dst
        if (Test-TarOk $dst) { $UsedSources.Value = @($the.FullName); return $dst }
        Write-Host "[WARN] $Date single-file verify failed after link/copy."
        if ($FORCE_EXTRACT_ON_INVALID) { $UsedSources.Value = @($the.FullName); return $dst }
        continue
      } else {
        Write-Host "[NEED] $Date split set incomplete after $($the.Name)."
        if ($FORCE_EXTRACT_ON_INVALID) { New-HardLinkOrCopy -Src $the.FullName -Dst $dst; $UsedSources.Value=@($the.FullName); return $dst }
        continue
      }
    }

    Write-Host "[JOIN] $Date trying stem '$($g.Stem)' ($(@($parts).Count) parts) -> $dst"
    $tarPath = Join-Parts-Resumable -Parts $parts -OutPath $dst -Date $Date
    if (Test-TarOk $tarPath)) {
      $UsedSources.Value = @($parts.FullName); Write-Host "[OK]   $Date verified."; return $tarPath
    } else {
      Write-Host "[FAIL] $Date candidate stem '$($g.Stem)' invalid."
      if ($FORCE_EXTRACT_ON_INVALID) { $UsedSources.Value=@($parts.FullName); return $tarPath }
      Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
    }
  }

  Show-PartDiagnostics $Date
  Write-Host "[FAIL] $Date all candidate sets invalid."
  if ($FORCE_EXTRACT_ON_INVALID) {
    Write-Host "[FORCE] proceeding with last attempt path: $dst"
    return $dst
  }
  return $null
}

# Extract only z=11 rectangle; proceed even on tar errors if FORCE enabled.
# Returns object: @{ Ok=bool; Partial=bool; Added=int }
function Extract-Box([string]$ArchivePath, [string]$TilesDir) {
  if (-not (Test-Path -LiteralPath $ArchivePath)) { Write-Host "[FAIL] archive missing: $ArchivePath"; return @{Ok=$false;Partial=$false;Added=0} }

  $prev = $ErrorActionPreference
  try { $ErrorActionPreference = "Continue"; $list = & tar -tzf $ArchivePath 2>$null; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $prev }

  if (-not $list -or @($list).Count -eq 0) {
    Write-Host "[FAIL] list produced no entries for $ArchivePath"
    return @{Ok=$false;Partial=$false;Added=0}
  }
  if ($code -ne 0) { Write-Host "[WARN] list exit=$code (possibly truncated) — attempting best-effort extract." }

  $first = $list | Select-Object -First 1
  if ($first -notmatch '^(.+?)/') { Write-Host "[FAIL] cannot detect prefix in $ArchivePath"; return @{Ok=$false;Partial=$false;Added=0} }
  $prefix = $Matches[1]

  $rx = '^' + [regex]::Escape($prefix) + '/(\d{1,4})/(\d{1,4})\.png$'
  $want = @($list | Where-Object {
    if ($_ -match $rx) {
      $x = [int]$Matches[1]; $y = [int]$Matches[2]
      ($x -ge $X_MIN -and $x -le $X_MAX -and $y -ge $Y_MIN -and $y -le $Y_MAX)
    } else { $false }
  })
  if (-not $want -or @($want).Count -eq 0) { Write-Host "[WARN] no files in target box for $ArchivePath"; return @{Ok=$false;Partial=$false;Added=0} }

  Ensure-Dir $TilesDir

  $existing = Get-ChildItem -LiteralPath $TilesDir -Recurse -File -Filter *.png -ErrorAction SilentlyContinue |
              ForEach-Object { $_.FullName.Substring($TilesDir.Length).TrimStart('\','/') -replace '\\','/' }
  $existingSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($e in $existing) { [void]$existingSet.Add($e) }

  $rxRel = '^' + [regex]::Escape($prefix) + '/(\d{1,4}/\d{1,4}\.png)$'
  $toExtract = @()
  foreach ($p in $want) {
    if ($p -match $rxRel) {
      $rel = $Matches[1]
      if (-not $existingSet.Contains($rel)) { $toExtract += $p }
    }
  }
  if (@($toExtract).Count -eq 0) { Write-Host "[XTR ] nothing to do; box already extracted -> $TilesDir"; return @{Ok=$true;Partial=$false;Added=0} }

  Write-Host "[XTR ] extracting $(@($toExtract).Count) files -> $TilesDir"
  $listFile = [System.IO.Path]::GetTempFileName()
  $xcode = 1
  $before = (Get-ChildItem -LiteralPath $TilesDir -Recurse -File -Filter *.png -ErrorAction SilentlyContinue | Measure-Object).Count
  try {
    Set-Content -LiteralPath $listFile -Value ($toExtract -join "`n") -Encoding ASCII
    $prev = $ErrorActionPreference
    try {
      $ErrorActionPreference = "Continue"
      & tar -xzf $ArchivePath -C $TilesDir --strip-components=1 -T $listFile 2>$null
      $xcode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
  } finally { Remove-Item -LiteralPath $listFile -Force -ErrorAction SilentlyContinue }

  $after = (Get-ChildItem -LiteralPath $TilesDir -Recurse -File -Filter *.png -ErrorAction SilentlyContinue | Measure-Object).Count
  $added = [int]($after - $before)

  if ($xcode -eq 0) {
    return @{Ok=$true;Partial=$false;Added=$added}
  } elseif ($FORCE_EXTRACT_ON_INVALID -and $added -gt 0) {
    Write-Host "[PART] extract exited $xcode but yielded $added files."
    return @{Ok=$true;Partial=$true;Added=$added}
  } else {
    Write-Host "[FAIL] extract failed (exit=$xcode, added=$added) for $ArchivePath"
    return @{Ok=$false;Partial=$false;Added=0}
  }
}

function Delete-Sources-ForDate([string]$Date, [string[]]$Used) {
  if (-not $Used -or @($Used).Count -eq 0) { return }
  foreach ($p in $Used) {
    try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; Write-Host "[DEL ] source: $p" }
    catch { Write-Host "[WARN] could not delete: $p ($($_.Exception.Message))" }
  }
}

# ----------------- MAIN -----------------
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
  Write-Host "ERROR: 'tar' not found in PATH. On Windows it’s usually $env:SystemRoot\System32\tar.exe"
  exit 1
}

Ensure-Dir $OUT_DIR
Ensure-Dir $OUT_ARCH

# Build date list for the window
$DATES = @()
for ($d=$START_DATE; $d -le $END_DATE; $d=$d.AddDays(1)) { $DATES += $d.ToString('yyyy-MM-dd') }

$N = @($DATES).Count
$k = 0
$mainId = 7001

foreach ($date in $DATES) {
  $k++
  $pct = [int](100.0 * $k / $N)
  Write-Progress -Id $mainId -Activity "Join+Extract (selected window)" -Status ("{0} / {1}: {2}" -f $k,$N,$date) -PercentComplete $pct

  $used = @()
  $tarPath = Ensure-Joined $date ([ref]$used)
  if (-not $tarPath) { continue }

  $tilesDir = Join-Path $OUT_DIR ("tiles_{0}" -f $date)
  $res = Extract-Box -ArchivePath $tarPath -TilesDir $tilesDir

  if ($res.Ok -and -not $res.Partial) {
    if ($DELETE_TAR_AFTER_EXTRACT) {
      try { Remove-Item -LiteralPath $tarPath -Force; Write-Host "[DEL ] archive: $tarPath" } catch {}
    }
    if ($DELETE_SOURCES_AFTER_SUCCESS) {
      Delete-Sources-ForDate -Date $date -Used $used
    }
  } elseif ($res.Ok -and $res.Partial) {
    Write-Host "[NOTE] kept sources and archive for $date (partial extract)."
  }
}

Write-Progress -Id $mainId -Completed -Activity "Join+Extract (selected window)"
Write-Host "Done."
