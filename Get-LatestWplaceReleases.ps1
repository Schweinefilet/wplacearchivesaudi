param(
  [string]$Owner = "murolem",
  [string]$Repo  = "wplace-archives",
  [string]$OutDir = "E:\Downloads E",
  [int]$DaysBack = 120
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
function Log($m){ Write-Host $m }

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$base   = "https://api.github.com"
$reUri  = "$base/repos/$Owner/$Repo/releases?per_page=100&page="
$hdrs = @{ "Accept"="application/vnd.github+json"; "User-Agent"="pwsh-wplace" }
if ($env:GITHUB_TOKEN) { $hdrs["Authorization"] = "Bearer $($env:GITHUB_TOKEN)"; Log "[INFO] Using GITHUB_TOKEN (authenticated rate limits)." }
else { Log "[INFO] No GITHUB_TOKEN in environment. You may hit GitHub rate limits."; }

# Pull pages until dates are older than DaysBack
$cutoff = (Get-Date).AddDays(-$DaysBack)
$releases = @()
for ($page=1; $page -le 10; $page++) {
  $r = Invoke-RestMethod -Uri ($reUri + $page) -Headers $hdrs -Method GET
  if (-not $r) { break }
  $releases += $r
  if (($r | Select-Object -Last 1).created_at -as [datetime] -lt $cutoff) { break }
}

# Gather only 'world-' releases and split assets
$world = $releases | Where-Object { $_.tag_name -like 'world-*' }
if (-not $world) { Log "[INFO] No world releases in the queried window."; exit 0 }

# Build map: Date (yyyy-MM-dd) -> newest Release
$grouped = @{}
foreach ($rel in $world) {
  # tag_name like world-2025-09-30T19-21-04.982Z
  if ($rel.tag_name -match '^world-(\d{4}-\d{2}-\d{2})T(\d{2}-\d{2}-\d{2}\.\d{3}Z)') {
    $d = $Matches[1]; $t = $Matches[2]
    $ticks = ([datetime]::ParseExact($t.Replace('-',':'), 'HH:mm:ss.fffZ', $null)).Ticks
    if (($grouped[$d] | ForEach-Object { $_.Ticks }) -lt $ticks) {
      $grouped[$d] = [pscustomobject]@{ Release=$rel; Ticks=$ticks }
    }
  }
}

if ($grouped.Count -eq 0) { Log "[INFO] No matching assets found in the last $DaysBack day(s)."; exit 0 }

foreach ($kv in $grouped.GetEnumerator() | Sort-Object Name) {
  $date = $kv.Key; $rel = $kv.Value.Release
  Log "[DATE] $date  tag=$($rel.tag_name) published=$([datetime]$rel.published_at)"

  # Select SPLIT PARTS ONLY
  $assets = @($rel.assets | Where-Object {
    $_.name -match '\.tar\.gz\.((?:[a-z]{2})|\d{3})$'
  })
  if (-not $assets) { Log "  [WARN] No split parts listed on this release. Skipping."; continue }

  # Download any part that is missing or size mismatched
  foreach ($a in $assets | Sort-Object name) {
    $dst = Join-Path $OutDir $a.name
    $need = $true
    if (Test-Path -LiteralPath $dst) {
      try {
        $local = (Get-Item -LiteralPath $dst).Length
        if ($local -eq [int64]$a.size) { $need = $false }
        else { Log ("  [SIZE] mismatch for {0}: local={1:N0} api={2:N0}" -f $a.name,$local,$a.size) }
      } catch {}
    }
    if (-not $need) { Log "  [HAVE] $($a.name)"; continue }

    $url = $a.browser_download_url
    Log "  [GET ] $($a.name)"
    try {
      Invoke-WebRequest -Uri $url -Headers $hdrs -OutFile $dst -UseBasicParsing
      # Verify size if API returns it
      if ($a.size -and (Get-Item -LiteralPath $dst).Length -ne [int64]$a.size) {
        throw "downloaded size mismatch"
      }
      Log "  [OK  ] $($a.name)"
    } catch {
      Log "  [FAIL] $($a.name): $($_.Exception.Message)"
      if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
    }
  }
}
