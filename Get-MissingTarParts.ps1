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

function Filter-YRange {
  param([Parameter(Mandatory)][string]$Root,[int]$YMin=875,[int]$YMax=904)
  Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | 
    Where-Object { $_.Name -match '^\d+$' } |
    ForEach-Object {
      $xDir = $_.FullName
      Get-ChildItem -LiteralPath $xDir -File -Filter "*.png" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.BaseName -match '^\d+$') {
          $y = [int]$_.BaseName
          if ($y -lt $YMin -or $y -gt $YMax) {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
          }
        }
      }
    }
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

  $has7z = Get-Command 7z -ErrorAction SilentlyContinue
  if ($has7z) {
    $includes = @(); for ($n=$XMin; $n -le $XMax; $n++){ $includes += "-i!*/$n/*.png" }
    Log ("  [7Z] selective extract x=$XMin-$XMax, y=$YMin-$YMax -> {0}" -f $DestDir)
    & 7z x -bd -y -so -- "$ArchivePath" | & 7z x -bd -y -si -ttar "-o$DestDir" @includes
    if ($LASTEXITCODE -ne 0) { throw "7z selective extract failed with code $LASTEXITCODE" }
    Flatten-Numeric -Root $DestDir -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax
    Remove-EmptyPngs -Root $DestDir
    return
  }

  if (-not (Get-Command tar -ErrorAction SilentlyContinue)) { throw "tar not found in PATH and 7z not found" }

  # Build patterns and compute how many leading components to strip
  $patterns = New-Object System.Collections.Generic.List[string]
  for ($n=$XMin; $n -le $XMax; $n++){
    $patterns.Add("*/$n/*.png"); $patterns.Add("*/*/$n/*.png")
  }
  $strip = Get-StripComponents -ArchivePath $ArchivePath -XMin $XMin -XMax $XMax

  Log ("  [TAR] selective extract x=$XMin-$XMax (strip $strip) -> {0}" -f $DestDir)
  & tar --extract --gzip --file "$ArchivePath" --strip-components=$strip -C "$DestDir" @patterns
  if ($LASTEXITCODE -ne 0) {
    & tar --extract --file "$ArchivePath" --strip-components=$strip -C "$DestDir" @patterns
  }
  # Filter Y coordinates after extraction
  Filter-YRange -Root $DestDir -YMin $YMin -YMax $YMax
  Remove-EmptyPngs -Root $DestDir
}
