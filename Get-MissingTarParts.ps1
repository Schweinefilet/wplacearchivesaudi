function Flatten-Numeric {
  param([Parameter(Mandatory)][string]$Root,[int]$KeepStart=1243,[int]$KeepEnd=1258)
  Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -notmatch '^\d+$') {
      Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+$' -and [int]$_.Name -ge $KeepStart -and [int]$_.Name -le $KeepEnd } |
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
}

function Get-StripComponents {
  param([Parameter(Mandatory)][string]$ArchivePath,[int]$KeepStart=1243,[int]$KeepEnd=1258)
  $members = & tar -tzf "$ArchivePath" 2>$null; if (-not $members) { $members = & tar -tf "$ArchivePath" }
  $strip = 0
  foreach ($m in $members) {
    if (-not $m -or $m[-1] -eq '/') { continue }
    $segs = $m.TrimEnd('/') -split '/'
    for ($i=0; $i -lt $segs.Count; $i++) {
      if ($segs[$i] -match '^\d+$') {
        $num = [int]$segs[$i]
        if ($num -ge $KeepStart -and $num -le $KeepEnd) { return $i }
      }
    }
  }
  return 0
}

function Extract-OnlyRange {
  param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$DestDir,
    [int]$KeepStart = 1243,
    [int]$KeepEnd   = 1258
  )
  Ensure-Dir $DestDir

  $has7z = Get-Command 7z -ErrorAction SilentlyContinue
  if ($has7z) {
    $includes = @(); for ($n=$KeepStart; $n -le $KeepEnd; $n++){ $includes += "-i!*/$n/*.png" }
    Log ("  [7Z] selective extract -> {0}" -f $DestDir)
    & 7z x -bd -y -so -- "$ArchivePath" | & 7z x -bd -y -si -ttar "-o$DestDir" @includes
    if ($LASTEXITCODE -ne 0) { throw "7z selective extract failed with code $LASTEXITCODE" }
    Flatten-Numeric -Root $DestDir -KeepStart $KeepStart -KeepEnd $KeepEnd
    Remove-EmptyPngs -Root $DestDir
    return
  }

  if (-not (Get-Command tar -ErrorAction SilentlyContinue)) { throw "tar not found in PATH and 7z not found" }

  # Build patterns and compute how many leading components to strip
  $patterns = New-Object System.Collections.Generic.List[string]
  for ($n=$KeepStart; $n -le $KeepEnd; $n++){
    $patterns.Add("*/$n/*.png"); $patterns.Add("*/*/$n/*.png")
  }
  $strip = Get-StripComponents -ArchivePath $ArchivePath -KeepStart $KeepStart -KeepEnd $KeepEnd

  Log ("  [TAR] selective extract (strip {0}) -> {1}" -f $strip, $DestDir)
  & tar --extract --gzip --file "$ArchivePath" --strip-components=$strip -C "$DestDir" @patterns
  if ($LASTEXITCODE -ne 0) {
    & tar --extract --file "$ArchivePath" --strip-components=$strip -C "$DestDir" @patterns
  }
  Remove-EmptyPngs -Root $DestDir
}
