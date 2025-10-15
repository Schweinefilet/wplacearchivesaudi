param(
  [string]$Owner   = "murolem",
  [string]$Repo    = "wplace-archives",
  [string]$OutDir  = "E:\Downloads",
  [string]$HaveDir = "E:\wplace-site\tiles",
  [int]$DaysBack   = 120
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProgressPreference = "SilentlyContinue"

function Log($m){ Write-Host $m }

# Ensure output dir exists
if (-not (Test-Path -LiteralPath $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

# Headers for GitHub API
$base  = "https://api.github.com"
$reUri = "$base/repos/$Owner/$Repo/releases?per_page=100&page="
$hdrs  = @{ "Accept"="application/vnd.github+json"; "User-Agent"="pwsh-wplace" }
if ($env:GITHUB_TOKEN) {
  $hdrs["Authorization"] = "Bearer $($env:GITHUB_TOKEN)"
  Log "[INFO] Using GITHUB_TOKEN."
} else {
  Log "[INFO] No GITHUB_TOKEN. You may hit API rate limits."
}

# Pull pages of releases until we pass the cutoff
$cutoff = (Get-Date).AddDays(-$DaysBack)
$releases = @()
for ($page = 1; $page -le 10; $page++) {
  $r = Invoke-RestMethod -Uri ($reUri + $page) -Headers $hdrs -Method GET
  if (-not $r) { break }
  $releases += $r
  $last = $r | Select-Object -Last 1
  if ($last -and ([datetime]$last.created_at) -lt $cutoff) { break }
}

# Keep only world-* releases
$world = $releases | Where-Object { $_.tag_name -like 'world-*' }
if (-not $world) { Log "[INFO] No world releases in window."; exit 0 }

# Pick the newest release for each date (yyyy-MM-dd) based on published_at
$grouped = @{}
foreach ($rel in $world) {
  if ($rel.tag_name -match '^world-(\d{4}-\d{2}-\d{2})T') {
    $d   = $Matches[1]
    $pub = [datetime]$rel.published_at
    if (-not $grouped.ContainsKey($d) -or $grouped[$d].Published -lt $pub) {
      $grouped[$d] = [pscustomobject]@{ Release = $rel; Published = $pub }
    }
  }
}

if ($grouped.Count -eq 0) { Log "[INFO] No matching daily releases."; exit 0 }

# Build a quick lookup of already-present files with sizes from HaveDir and OutDir
$have = @{}
foreach ($dir in @($HaveDir, $OutDir)) {
  if ([string]::IsNullOrWhiteSpace($dir)) { continue }
  if (-not (Test-Path -LiteralPath $dir)) { continue }
  Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
    # Prefer the largest size seen for any duplicate name across dirs
    if (-not $have.ContainsKey($_.Name) -or $have[$_.Name] -lt $_.Length) {
      $have[$_.Name] = $_.Length
    }
  }
}

foreach ($kv in $grouped.GetEnumerator() | Sort-Object Name) {
  $date = $kv.Key
  $rel  = $kv.Value.Release
  Log "[DATE] $date  tag=$($rel.tag_name)  published=$([datetime]$rel.published_at)"

  # Select split parts (*.tar.gz.aa .. or *.tar.gz.000)
  $assets = @($rel.assets | Where-Object { $_.name -match '\.tar\.gz\.((?:[a-z]{2})|\d{3})$' })
  if (-not $assets) { Log "  [WARN] No split parts. Skipping."; continue }

  foreach ($a in $assets | Sort-Object name) {
    $name = $a.name
    $dst  = Join-Path $OutDir $name
    $need = $true

    # Skip if already present in HaveDir or OutDir with matching size
    $apiSize = if ($a.size) { [int64]$a.size } else { $null }
    if ($have.ContainsKey($name) -and $apiSize -and $have[$name] -eq $apiSize) {
      Log "  [HAVE] $name (already present in HaveDir/OutDir)"
      $need = $false
    } elseif ((Test-Path -LiteralPath $dst) -and $apiSize) {
      try {
        $local = (Get-Item -LiteralPath $dst).Length
        if ($local -eq $apiSize) { Log "  [HAVE] $name (in OutDir)"; $need = $false }
        else { Log ("  [SIZE] mismatch for {0}: local={1:N0} api={2:N0}" -f $name,$local,$apiSize) }
      } catch {}
    }

    if (-not $need) { continue }

    $url = $a.browser_download_url
    Log "  [GET ] $name"
    try {
      Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -ErrorAction Stop
      if ($apiSize -and (Get-Item -LiteralPath $dst).Length -ne $apiSize) {
        throw "downloaded size mismatch"
      }
      # Track as present for later parts this run
      if ($apiSize) { $have[$name] = $apiSize }
      Log "  [OK  ] $name"
    } catch {
      Log "  [FAIL] $name: $($_.Exception.Message)"
      if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
    }
  }
}
