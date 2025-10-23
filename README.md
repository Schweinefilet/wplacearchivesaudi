# wplace-archive-saudi# wplace-archive-tools



**Wplace Archive Viewer for Mecca, Medina & Taif** — Interactive timeline viewer for r/place activity in western Saudi Arabia.**Wplace Archive Viewer for Mecca + Medina** — static site + scripts that download, join, and trim daily world dumps to a small z=11 rectangle over western Saudi Arabia, then publish a browsable timeline.



**Live site:** https://schweinefilet.github.io/wplacearchivesaudi/**Live site:** https://schweinefilet.github.io/wplacearchivesaudi/



> Built to archive **Mecca, Medina, and Taif** activity on wplace.live for **islamwp**.  > Built for **Mecca + Medina** archiving purposes on wplace.live for **islamwp**.  

> Archives sourced from **https://github.com/murolem/wplace-archives**.> Archives are taken from **https://github.com/murolem/wplace-archives**.



------



## What this repo contains## What this repo contains



- **`index.html`** — Interactive Leaflet viewer with timeline scrubbing, keyboard controls, HUD toggle, and 4K export functionality- **`index.html`** — Leaflet viewer that fetches `snaps.json` and overlays day folders; timeline scrub, HUD, prev/next keys, and quick 4K exports.

- **`snaps.json`** — Timeline metadata:  - **`snaps.json`** — array of objects:  

  ```json  `[{ "label": "YYYY-MM-DD", "dir": "tiles/tiles_YYYY-MM-DD" }, …]`

  [- **`tiles/tiles_YYYY-MM-DD/{x}/{y}.png`** — trimmed z=11 tiles for the Saudi rectangle (x=1243…1258, y=875…904).

    { "label": "2025-08-22", "dir": "tiles/tiles_2025-08-22" },- **Scripts** (Windows-focused):

    ...  - `Get-LatestWplaceReleases.ps1/.bat` — pull the **latest** dump per day (handles split parts).

  ]  - `Make-JoinedTars.ps1` — join parts (resume-safe), verify, **trim** to the rectangle, export `tiles_YYYY-MM-DD`.

  ```  - `Publish-Site.ps1/.bat` — mirror new `tiles_*` into `/tiles/`, rebuild `snaps.json`, commit, push.

- **`tiles/tiles_YYYY-MM-DD/{x}/{y}.png`** — Trimmed z=11 tiles for the Saudi rectangle (X=1243-1253, Y=875-904)- (Optional) **GitHub Actions** workflow to run the whole thing on GitHub daily (no PC needed).

- **`Sync-Tiles.ps1`** — Unified PowerShell script to download and extract tiles, ensuring complete coverage (X=1243-1253)

---

---

## Coordinates & zoom

## Coverage Area

- **Zoom:** 11  

- **Zoom level:** 11  - **Rectangle:** `x = 1243…1258`, `y = 875…904`  

- **X range:** 1243-1253 (Mecca → Taif)Covers Mecca, Medina, Jeddah, Taif at z=11.

- **Y range:** 875-904  

- **Coordinates:** Covers Mecca (21.42°N, 39.83°E), Medina (24.47°N, 39.61°E), and Taif (21.27°N, 40.42°E)---



---## Directory layout



## Quick Start (Windows)<<<<<<< HEAD

```

### 1. Set up GitHub token (optional, for higher rate limits)

```powershell=======

$env:GITHUB_TOKEN = "your_github_token_here">>>>>>> 71a04c6 (publish: sync tiles/* + snaps.json (49 dates))

```/ (repo root)

├─ index.html

### 2. Sync tiles├─ snaps.json

```powershell├─ tiles/

# Download missing dates and X folders<<<<<<< HEAD

.\Sync-Tiles.ps1 -ParallelJobs 16│  ├─ tiles_2025-10-09/

│  │  └─ 1257/883.png … 1258/904.png

# Or with custom paths│  └─ tiles_YYYY-MM-DD/…

.\Sync-Tiles.ps1 -TilesRoot "E:\wplace-site\tiles" -TempDir "E:\wplace-archive"=======

```│ ├─ tiles_2025-10-09/

│ │ └─ 1257/883.png … 1258/904.png

### 3. Update snaps.json│ └─ tiles_YYYY-MM-DD/…

```powershell>>>>>>> 71a04c6 (publish: sync tiles/* + snaps.json (49 dates))

$sn = Get-ChildItem -LiteralPath .\tiles -Directory | Sort-Object Name | ForEach-Object {├─ Get-LatestWplaceReleases.ps1

  $has = Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter *.png -File -ErrorAction SilentlyContinue | Select-Object -First 1├─ Make-JoinedTars.ps1

  if ($has) { [pscustomobject]@{ label = ($_.Name -replace '^tiles_',''); dir = ('tiles/' + $_.Name) } }├─ Publish-Site.ps1

}└─ .github/workflows/ (optional)

$sn | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath .\snaps.json -Encoding UTF8

```<<<<<<< HEAD

````

### 4. View locally=======

```powershellyaml

python -m http.server 8000Copy code

# Open http://localhost:8000/>>>>>>> 71a04c6 (publish: sync tiles/* + snaps.json (49 dates))

```

---

---

## Quick start (Windows, local)

## Viewer Controls<<<<<<< HEAD



- **Timeline:** Use slider, arrow buttons, or **← / →** keys to navigate dates1) **Download latest-per-day assets** into your staging folder:

- **Quick jumps:** Click **Mecca** or **Medina** buttons```powershell

- **Frame tool:** # Optional: higher API rate limits

  - Drag the white rectangle to select an area[Environment]::SetEnvironmentVariable("GITHUB_TOKEN","<your_token>","User")

  - Press **F** to toggle visibility$env:GITHUB_TOKEN = "<your_token>"

  - Use **WASD** keys to nudge (Alt=1px, Shift=50px steps)

- **4K Export:** Click **4K Mecca**, **4K Medina**, or **4K (Frame)** buttons# Download (adjust inside the script if needed)

- **HUD toggle:** Press **H** to hide/show controls.\Get-LatestWplaceReleases.bat

- **Debug mode:** Press **D** or click **DBG** button````



---2. **Join + Extract** (resume-safe; trims to the rectangle; cleans up on full success):



## How Sync-Tiles.ps1 Works```powershell

.\Run-Joiner.bat

The unified script intelligently manages your tile collection:# Resulting tiles end up in: E:\wplace-archive\tiles_YYYY-MM-DD\{x}\{y}.png

```

1. **Scans** your `tiles/` directory to find missing X folders (1243-1253) for each date

2. **Detects** three archive types:3. **Publish the site** (mirrors tiles to `/tiles`, rebuilds `snaps.json`, commits, pushes):

   - Single complete `.tar.gz` files

   - Single `.tar.gz.aa` files (treated as complete)```powershell

   - Multi-part archives (`.aa`, `.ab`, `.ac`, etc.).\Publish-Site.bat

3. **Downloads** only what's needed:```

   - Missing dates → Full archive

   - Partial dates → Only missing X folders4. **View locally** (optional):

4. **Extracts** and filters to Y range (875-904)

5. **Cleans up** temporary files```powershell

# from repo root

### Parameterspython -m http.server 8000

# then open:

```powershell# http://localhost:8000/

-TilesRoot "E:\wplace-site\tiles"  # Where to store tiles```

-TempDir "E:\wplace-archive"       # Temp extraction directory

-StartDate "2025-08-01"            # Start of date range---

-EndDate "2025-10-23"              # End of date range  

-XMin 1243                         # Western boundary## Auto-updates (choose one)

-XMax 1253                         # Eastern boundary (includes Taif)

-YMin 875                          # Northern boundary### A) Windows Task Scheduler (PC must be on)

-YMax 904                          # Southern boundary

-ParallelJobs 16                   # Number of parallel downloadsSchedule the **publish** step daily:

```

```powershell

---$taskName = 'wplace_publish_site'

$ps1      = 'E:\wplace-site\Publish-Site.ps1'

## Troubleshooting

# Remove existing task (optional)

**Blank viewer:**if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {

- Check that `snaps.json` exists and has valid entries  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

- Verify `dir` paths match actual folder names: `"tiles/tiles_YYYY-MM-DD"`}

- Ensure PNG files exist in the date folders

# Run daily at 00:05 under your user (uses your Git creds)

**Missing tiles:**$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"`"$ps1`"`""

- Run `Sync-Tiles.ps1` to detect and fill gaps$trigger = New-ScheduledTaskTrigger -Daily -At 00:05

- Check that X range includes 1243-1253 (not just 1243-1250)Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Description 'Publish wplace site daily' | Out-Null

```

**GitHub Pages not updating:**

- Confirm pushes are landing on `main` branch> Make sure the account running the task has working Git credentials (Git Credential Manager).

- Check repository Settings → Pages is set to "Deploy from branch: main / (root)"

- Wait 2-3 minutes for rebuild### B) GitHub Actions (no PC needed)



**PowerShell errors:**Create `.github/workflows/publish.yml` in this repo to auto-fetch the next date’s latest dump from `murolem/wplace-archives`, extract the rectangle into `tiles/tiles_YYYY-MM-DD`, update `snaps.json`, and push. Example workflow:

- Ensure you have PowerShell 7+ for parallel processing

- Check that `tar` or `7z` is available in PATH```yaml

- Verify `GITHUB_TOKEN` environment variable if hitting rate limitsname: Publish tiles daily

on:

---  schedule:

    - cron: '10 1 * * *'   # 01:10 UTC daily

## License  workflow_dispatch: {}

permissions:

MIT  contents: write

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install jq
        run: sudo apt-get update && sudo apt-get install -y jq

      - name: Decide target date (next after last in snaps.json, else yesterday)
        id: dates
        shell: bash
        run: |
          if [ -f snaps.json ] && [ -s snaps.json ]; then
            last=$(jq -r '.[-1].label // empty' snaps.json)
          else
            last=""
          fi
          if [ -n "$last" ]; then
            target=$(date -u -d "$last + 1 day" +%F)
          else
            target=$(date -u -d "yesterday" +%F)
          fi
          echo "target=$target" >> $GITHUB_OUTPUT

      - name: Find latest asset stem on murolem/wplace-archives for that date
        id: find
        env: { GH_TOKEN: ${{ secrets.GITHUB_TOKEN }} }
        shell: bash
        run: |
          set -e
          target="${{ steps.dates.outputs.target }}"
          gh api -H "Accept: application/vnd.github+json" /repos/murolem/wplace-archives/releases?per_page=100 > releases.json
          jq -r --arg d "$target" '
            .[] | .assets[] | select(.name | test($d) and test("\\.tar\\.gz"))
            | {name: .name, url: .browser_download_url}
          ' releases.json > assets.json
          if [ ! -s assets.json ]; then
            echo "skip=true" >> $GITHUB_OUTPUT
            exit 0
          fi
          jq -r '
            . as $a | $a.name as $n
            | ($n | sub("\\.tar\\.gz\\.(?:[a-z]{2}|\\d{3})$";"") | sub("\\.tar\\.gz$";"")) as $stem
            | {stem:$stem, name:$a.name, url:$a.url}
          ' assets.json > withstems.json
          stem=$(jq -r 'sort_by(.name) | reverse | .[0].stem' withstems.json)
          echo "stem=$stem" >> $GITHUB_OUTPUT
          jq -r --arg s "$stem" 'select(.stem==$s) | .url' withstems.json > urls.txt
          echo "Selected URLs:"; cat urls.txt

      - name: Download assets
        if: steps.find.outputs.stem != ''
        shell: bash
        run: |
          mkdir -p work && cd work
          while read -r u; do curl -sS -L --fail -O "$u"; done < ../urls.txt
          ls -l

      - name: Join (if split) → archive.tar.gz
        if: steps.find.outputs.stem != ''
        shell: bash
        run: |
          cd work
          if ls *.tar.gz.* >/dev/null 2>&1; then
            cat $(ls -1 *.tar.gz.* | sort) > archive.tar.gz
          else
            mv *.tar.gz archive.tar.gz
          fi
          ls -lh archive.tar.gz

      - name: Extract Saudi rectangle (z=11 x=1243..1258, y=875..904)
        if: steps.find.outputs.stem != ''
        shell: bash
        run: |
          set -e
          cd work
          target="${{ steps.dates.outputs.target }}"
          mkdir -p "../tiles/tiles_$target"
          prefix=$(tar -tzf archive.tar.gz | head -1 | sed 's#/.*##')
          tar -tzf archive.tar.gz | awk -v p="$prefix" '
            match($0, "^" p "/([0-9]+)/([0-9]+)\\.png$", m) {
              x=m[1]; y=m[2];
              if (x>=1243 && x<=1258 && y>=875 && y<=904) print $0;
            }
          ' > want.txt
          cnt=$(wc -l < want.txt)
          [ "$cnt" -gt 0 ]
          tar -xzf archive.tar.gz --strip-components=1 -T want.txt -C "../tiles/tiles_$target"
          echo "Extracted $cnt files into tiles/tiles_$target"

      - name: Update snaps.json
        if: steps.find.outputs.stem != ''
        shell: bash
        run: |
          target="${{ steps.dates.outputs.target }}"
          tmp=snaps.json.new
          jq --arg d "$target" --arg dir "tiles/tiles_$target" '
            ( . // [] ) as $arr
            | if ($arr | map(.label) | index($d)) then $arr else ($arr + [{"label":$d,"dir":$dir}]) end
          ' snaps.json > "$tmp"
          mv "$tmp" snaps.json

      - name: Commit & push
        if: steps.find.outputs.stem != ''
        env:
          GIT_AUTHOR_NAME: github-actions
          GIT_AUTHOR_EMAIL: actions@users.noreply.github.com
          GIT_COMMITTER_NAME: github-actions
          GIT_COMMITTER_EMAIL: actions@users.noreply.github.com
        run: |
          git add snaps.json tiles/*
          git commit -m "Add tiles for ${{ steps.dates.outputs.target }}" || true
          git push
```

---

## Regenerating `snaps.json` (after moves/cleanup)

```powershell
# from repo root
$sn = Get-ChildItem -LiteralPath .\tiles -Directory | Sort-Object Name | ForEach-Object {
  $has = Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter *.png -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($has) { [pscustomobject]@{ label = ($_.Name -replace '^tiles_',''); dir = ('tiles/' + $_.Name) } }
}
$sn | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath .\snaps.json -Encoding UTF8
```

---

## Troubleshooting

* **Blank viewer** → `snaps.json` missing/empty, `dir` paths wrong, or no PNGs under that day. Ensure entries look like `"dir": "tiles/tiles_YYYY-MM-DD"`.
* **Join fails / partials** → multiple split sets may exist per day; try the newest timestamp stem; keep “force extract” behavior in your joiner to salvage usable tiles.
* **Pages not updating** → confirm pushes land on `main`, and repo Settings → Pages is set to “Deploy from a branch: main / (root)”.


=======

1) **Download latest-per-day assets** into your staging folder:
```powershell
# Optional: higher API rate limits
[Environment]::SetEnvironmentVariable("GITHUB_TOKEN","<your_token>","User")
$env:GITHUB_TOKEN = "<your_token>"

# Download (adjust inside the script if needed)
.\Get-LatestWplaceReleases.bat
Join + Extract (resume-safe; trims to the rectangle; cleans up on full success):

powershell
Copy code
.\Run-Joiner.bat
# Resulting tiles end up in: E:\wplace-archive\tiles_YYYY-MM-DD\{x}\{y}.png
Publish the site (mirrors tiles to /tiles, rebuilds snaps.json, commits, pushes):

powershell
Copy code
.\Publish-Site.bat
View locally (optional):

powershell
Copy code
# from repo root
python -m http.server 8000
# then open:
# http://localhost:8000/
Auto-updates (choose one)
A) Windows Task Scheduler (PC must be on)
Schedule the publish step daily:

powershell
Copy code
$taskName = 'wplace_publish_site'
$ps1      = 'E:\wplace-site\Publish-Site.ps1'

# Remove existing task (optional)
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# Run daily at 00:05 under your user (uses your Git creds)
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"`"$ps1`"`""
$trigger = New-ScheduledTaskTrigger -Daily -At 00:05
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Description 'Publish wplace site daily' | Out-Null
Make sure the account running the task has working Git credentials (Git Credential Manager).

B) GitHub Actions (no PC needed)
Create .github/workflows/publish.yml in this repo to auto-fetch the next date’s latest dump from murolem/wplace-archives, extract the rectangle into tiles/tiles_YYYY-MM-DD, update snaps.json, and push. Example workflow:

yaml
Copy code
name: Publish tiles daily
on:
  schedule:
    - cron: '10 1 * * *'   # 01:10 UTC daily
  workflow_dispatch: {}
permissions:
  contents: write
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install jq
        run: sudo apt-get update && sudo apt-get install -y jq

      - name: Decide target date (next after last in snaps.json, else yesterday)
        id: dates
        shell: bash
        run: |
          if [ -f snaps.json ] && [ -s snaps.json ]; then
            last=$(jq -r '.[-1].label // empty' snaps.json)
          else
            last=""
          fi
          if [ -n "$last" ]; then
            target=$(date -u -d "$last + 1 day" +%F)
          else
            target=$(date -u -d "yesterday" +%F)
          fi
          echo "target=$target" >> $GITHUB_OUTPUT

      - name: Find latest asset stem on murolem/wplace-archives for that date
        id: find
        env: { GH_TOKEN: ${{ secrets.GITHUB_TOKEN }} }
        shell: bash
        run: |
          set -e
          target="${{ steps.dates.outputs.target }}"
          gh api -H "Accept: application/vnd.github+json" /repos/murolem/wplace-archives/releases?per_page=100 > releases.json
          jq -r --arg d "$target" '
            .[] | .assets[] | select(.name | test($d) and test("\\.tar\\.gz"))
            | {name: .name, url: .browser_download_url}
          ' releases.json > assets.json
          if [ ! -s assets.json ]; then
            echo "skip=true" >> $GITHUB_OUTPUT
            exit 0
          fi
          jq -r '
            . as $a | $a.name as $n
            | ($n | sub("\\.tar\\.gz\\.(?:[a-z]{2}|\\d{3})$";"") | sub("\\.tar\\.gz$";"")) as $stem
            | {stem:$stem, name:$a.name, url:$a.url}
          ' assets.json > withstems.json
          stem=$(jq -r 'sort_by(.name) | reverse | .[0].stem' withstems.json)
          echo "stem=$stem" >> $GITHUB_OUTPUT
          jq -r --arg s "$stem" 'select(.stem==$s) | .url' withstems.json > urls.txt
          echo "Selected URLs:"; cat urls.txt

      - name: Download assets
        if: steps.find.outputs.stem != ''
        shell: bash
        run: |
          mkdir -p work && cd work
          while read -r u; do curl -sS -L --fail -O "$u"; done < ../urls.txt
          ls -l

      - name: Join (if split) → archive.tar.gz
        if: steps.find.outputs.stem != ''
        shell: bash
        run: |
          cd work
          if ls *.tar.gz.* >/dev/null 2>&1; then
            cat $(ls -1 *.tar.gz.* | sort) > archive.tar.gz
          else
            mv *.tar.gz archive.tar.gz
          fi
          ls -lh archive.tar.gz

      - name: Extract Saudi rectangle (z=11 x=1243..1258, y=875..904)
        if: steps.find.outputs.stem != ''
        shell: bash
        run: |
          set -e
          cd work
          target="${{ steps.dates.outputs.target }}"
          mkdir -p "../tiles/tiles_$target"
          prefix=$(tar -tzf archive.tar.gz | head -1 | sed 's#/.*##')
          tar -tzf archive.tar.gz | awk -v p="$prefix" '
            match($0, "^" p "/([0-9]+)/([0-9]+)\\.png$", m) {
              x=m[1]; y=m[2];
              if (x>=1243 && x<=1258 && y>=875 && y<=904) print $0;
            }
          ' > want.txt
          cnt=$(wc -l < want.txt)
          [ "$cnt" -gt 0 ]
          tar -xzf archive.tar.gz --strip-components=1 -T want.txt -C "../tiles/tiles_$target"
          echo "Extracted $cnt files into tiles/tiles_$target"

      - name: Update snaps.json
        if: steps.find.outputs.stem != ''
        shell: bash
        run: |
          target="${{ steps.dates.outputs.target }}"
          tmp=snaps.json.new
          jq --arg d "$target" --arg dir "tiles/tiles_$target" '
            ( . // [] ) as $arr
            | if ($arr | map(.label) | index($d)) then $arr else ($arr + [{"label":$d,"dir":$dir}]) end
          ' snaps.json > "$tmp"
          mv "$tmp" snaps.json

      - name: Commit & push
        if: steps.find.outputs.stem != ''
        env:
          GIT_AUTHOR_NAME: github-actions
          GIT_AUTHOR_EMAIL: actions@users.noreply.github.com
          GIT_COMMITTER_NAME: github-actions
          GIT_COMMITTER_EMAIL: actions@users.noreply.github.com
        run: |
          git add snaps.json tiles/*
          git commit -m "Add tiles for ${{ steps.dates.outputs.target }}" || true
          git push
Regenerating snaps.json (after moves/cleanup)
powershell
Copy code
# from repo root
$sn = Get-ChildItem -LiteralPath .\tiles -Directory | Sort-Object Name | ForEach-Object {
  $has = Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter *.png -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($has) { [pscustomobject]@{ label = ($_.Name -replace '^tiles_',''); dir = ('tiles/' + $_.Name) } }
}
$sn | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath .\snaps.json -Encoding UTF8
Troubleshooting
Blank viewer → snaps.json missing/empty, dir paths wrong, or no PNGs under that day. Ensure entries look like "dir": "tiles/tiles_YYYY-MM-DD".

Join fails / partials → multiple split sets may exist per day; try the newest timestamp stem; keep “force extract” behavior in your joiner to salvage usable tiles.

Pages not updating → confirm pushes land on main, and repo Settings → Pages is set to “Deploy from a branch: main / (root)”.

MIT.
>>>>>>> 71a04c6 (publish: sync tiles/* + snaps.json (49 dates))
