# wplace-archive-tools

Built for **Mecca + Medina archiving purposes on wplace.live for islamwp**.
Archives are taken from **https://github.com/murolem/wplace-archives**.

This toolkit:
- Downloads the latest per-day world-YYYY-MM-DDT... dumps (chooses the latest timestamp per day; grabs split parts).
- Joins split *.tar.gz.aa/.ab/.ac/... into archive_YYYY-MM-DD.tar.gz (resume-safe).
- Extracts only the z=11 Saudi rectangle tiles (Mecca/Medina/Jeddah/Taif) to tiles_YYYY-MM-DD/{x}/{y}.png.
- Views the tiles in a minimal Leaflet app with date scrub + 4K export.

> Coordinates box @ z=11: x 1243–1258, y 875–904.

---
## Repo Layout
| File | Purpose |
|---|---|
| .gitattributes | Normalize line endings; safe diffs |
| .gitignore | Ignore logs, large archives, temp artifacts |
| Get-LatestWplaceReleases.ps1 | Downloader (PowerShell). Groups by date, picks latest per day, downloads all split parts (.aa/.ab/.ac/.ad or .001/.002/...). Skips exact-size matches |
| Get-LatestWplaceReleases.bat | One-click launcher for the downloader (logs and pauses) |
| Make-JoinedTars.ps1 | Join + Extract. Resumable join; verify; optional force-extract for truncated tars; trims to the z=11 box; cleans up on success |
| Run-Joiner.bat | One-click launcher for the join/extract script |
| get-latest.log | Rolling log from the downloader .bat |
| wplace_leaflet.html | Minimal Leaflet viewer for tiles_* folders; date slider; HUD; 4K export buttons |

---
## Requirements
- Windows 10/11
- PowerShell 5.1+ (or PowerShell 7)
- tar.exe on PATH (Windows built-in: %SystemRoot%\System32\tar.exe)
- (Recommended) GitHub token via GITHUB_TOKEN for higher API limits

---
## Quick Start
1) Download per-day latest releases to E:\Downloads E
   - Double-click Get-LatestWplaceReleases.bat
   - Logs: E:\wplace-archive\get-latest.log
   - Token (recommended):
     [Environment]::SetEnvironmentVariable("GITHUB_TOKEN","ghp_your_token","User")
     $env:GITHUB_TOKEN = "ghp_your_token"

2) Join + Extract tiles to E:\wplace-archive\tiles_YYYY-MM-DD
   - Double-click Run-Joiner.bat

3) View
   - Open wplace_leaflet.html. If file:// images are blocked, run a local server:
     # python -m http.server 8000
     # Start-Process msedge "http://localhost:8000/wplace_leaflet.html"

---
## Configuration
### Downloader (Get-LatestWplaceReleases.ps1)
param(
  [string]$Owner   = "murolem",
  [string]$Repo    = "wplace-archives",
  [string]$OutDir  = "E:\Downloads E",
  [int]   $DaysBack = 120
)

### Join + Extract (Make-JoinedTars.ps1)
$ROOTS    = @("E:\Downloads E")
$OUT_DIR  = "E:\wplace-archive"
$OUT_ARCH = $OUT_DIR
$X_MIN=1243; $X_MAX=1258
$Y_MIN=875;  $Y_MAX=904
$DELETE_SOURCES_AFTER_SUCCESS = $true
$DELETE_TAR_AFTER_EXTRACT     = $true
$FORCE_EXTRACT_ON_INVALID     = $true

---
## Typical Output
E:\wplace-archive\
  tiles_2025-09-25\
    1243\875.png
    ...
    1258\904.png
  (optional, deleted on clean success):
  archive_2025-09-25.tar.gz

---
## Reading the Messages
- [GET ] <name>   downloader fetching an asset
- [HAVE] <name>   already present with matching size
- [JOIN] date     joining N parts -> archive_...
- [OK]   date     tar verified
- [FORCE]         verification failed, extraction proceeds best-effort
- [XTR ]          extracting N files -> tiles_date
- [PART]          extraction errored but produced files; artifacts kept
- [DEL ]          cleanup after clean success
- [MISS]          no parts found under $ROOTS

---
## Troubleshooting
- Downloader finds nothing -> the repo ships split parts; use this repo's downloader (targets .tar.gz.<suffix>).
- Join fails but files exist -> multiple split sets for the same day; joiner tries newest-first and doesn't stop after the first bad set.
- Truncated tar -> keep FORCE_EXTRACT_ON_INVALID = $true to salvage tiles; artifacts are kept for retry.
- Zero files -> the day may not contain your z=11 box. Quick check:
tar -tzf E:\wplace-archive\archive_YYYY-MM-DD.tar.gz | Select-String "/(12(43|4[0-9]|5[0-8]))/(875|87[6-9]|88[0-9]|89[0-9]|90[0-4])\.png"

---
## Viewer (wplace_leaflet.html)
- Works next to tiles_* or via any static server.
- Timeline slider, HUD, Mecca/Medina/Mid shortcuts, 4K export buttons.
- One-liner (commented so it will not run when pasted):
# python -m http.server 8000 ; Start-Process msedge "http://localhost:8000/wplace_leaflet.html"

---
## License
MIT
