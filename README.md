# wplace-archive-saudi

**Wplace Archive Viewer for Mecca, Medina & Taif** — Interactive timeline viewer for r/place activity in western Saudi Arabia.

**Live site:** https://schweinefilet.github.io/wplacearchivesaudi/

> Built to archive **Mecca, Medina, and Taif** activity on wplace.live for **islamwp**.  
> Archives sourced from **https://github.com/murolem/wplace-archives**.

---

## What this repo contains

- **`index.html`** — Interactive Leaflet viewer with timeline scrubbing, keyboard controls, HUD toggle, and 4K export functionality
- **`snaps.json`** — Timeline metadata array:
  ```json
  [
    { "label": "2025-08-22", "dir": "tiles/tiles_2025-08-22" },
    ...
  ]
  ```
- **`tiles/tiles_YYYY-MM-DD/{x}/{y}.png`** — Trimmed z=11 tiles for the Saudi rectangle (X=1243-1253, Y=875-904)
- **Scripts** (Windows-focused):
  - `Sync-Tiles.ps1` — Unified script to download and extract tiles, ensuring complete coverage
  - `Get-LatestWplaceReleases.ps1/.bat` — Pull the latest dump per day (handles split parts)
  - `Make-JoinedTars.ps1` — Join parts (resume-safe), verify, trim to rectangle, export tiles
  - `Publish-Site.ps1/.bat` — Mirror new tiles into `/tiles/`, rebuild `snaps.json`, commit, push
- **(Optional)** GitHub Actions workflow to run the whole thing on GitHub daily (no PC needed)

---

## Coverage Area

- **Zoom level:** 11
- **X range:** 1243-1253 (Mecca → Taif)
- **Y range:** 875-904
- **Coordinates:** Covers Mecca (21.42°N, 39.83°E), Medina (24.47°N, 39.61°E), and Taif (21.27°N, 40.42°E)

---

## Quick Start (Windows)

### 1. Set up GitHub token (optional, for higher rate limits)

\`\`\`powershell
$env:GITHUB_TOKEN = "your_github_token_here"
\`\`\`

### 2. Sync tiles

\`\`\`powershell
# Download missing dates and X folders
.\Sync-Tiles.ps1 -ParallelJobs 16

# Or with custom paths
.\Sync-Tiles.ps1 -TilesRoot "E:\wplace-site\tiles" -TempDir "E:\wplace-archive"
\`\`\`

### 3. Update snaps.json

\`\`\`powershell
$sn = Get-ChildItem -LiteralPath .\tiles -Directory | Sort-Object Name | ForEach-Object {
  $has = Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter *.png -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($has) { [pscustomobject]@{ label = ($_.Name -replace '^tiles_',''); dir = ('tiles/' + $_.Name) } }
}
$sn | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath .\snaps.json -Encoding UTF8
\`\`\`

### 4. View locally

\`\`\`powershell
python -m http.server 8000
# Open http://localhost:8000/
\`\`\`

---

## Viewer Controls

- **Timeline:** Use slider, arrow buttons, or **← / →** keys to navigate dates
- **Quick jumps:** Click **Mecca** or **Medina** buttons
- **Frame tool:**
  - Drag the white rectangle to select an area
  - Press **F** to toggle visibility
  - Use **WASD** keys to nudge (Alt=1px, Shift=50px steps)
- **4K Export:** Click **4K Mecca**, **4K Medina**, or **4K (Frame)** buttons
- **HUD toggle:** Press **H** to hide/show controls
- **Debug mode:** Press **D** or click **DBG** button

---

## How Sync-Tiles.ps1 Works

The unified script intelligently manages your tile collection:

1. **Scans** your \`tiles/\` directory to find missing X folders (1243-1253) for each date
2. **Detects** three archive types:
   - Single complete \`.tar.gz\` files
   - Single \`.tar.gz.aa\` files (treated as complete)
   - Multi-part archives (\`.aa\`, \`.ab\`, \`.ac\`, etc.)
3. **Downloads** only what's needed:
   - Missing dates → Full archive
   - Partial dates → Only missing X folders
4. **Extracts** and filters to Y range (875-904)
5. **Cleans up** temporary files

### Parameters

\`\`\`powershell
-TilesRoot "E:\wplace-site\tiles"  # Where to store tiles
-TempDir "E:\wplace-archive"       # Temp extraction directory
-StartDate "2025-08-01"            # Start of date range
-EndDate "2025-10-23"              # End of date range  
-XMin 1243                         # Western boundary
-XMax 1253                         # Eastern boundary (includes Taif)
-YMin 875                          # Northern boundary
-YMax 904                          # Southern boundary
-ParallelJobs 16                   # Number of parallel downloads
\`\`\`

---

## Auto-updates (choose one)

### A) Windows Task Scheduler (PC must be on)

Schedule the **publish** step daily:

\`\`\`powershell
$taskName = 'wplace_publish_site'
$ps1      = 'E:\wplace-site\Publish-Site.ps1'

# Remove existing task (optional)
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# Run daily at 00:05 under your user (uses your Git creds)
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \\\`"\\\`"$ps1\\\`"\\\`""
$trigger = New-ScheduledTaskTrigger -Daily -At 00:05
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Description 'Publish wplace site daily' | Out-Null
\`\`\`

> Make sure the account running the task has working Git credentials (Git Credential Manager).

### B) GitHub Actions (no PC needed)

Create \`.github/workflows/publish.yml\` in this repo to auto-fetch the next date's latest dump from \`murolem/wplace-archives\`, extract the rectangle into \`tiles/tiles_YYYY-MM-DD\`, update \`snaps.json\`, and push. Example workflow:

\`\`\`yaml
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
        env: { GH_TOKEN: \${{ secrets.GITHUB_TOKEN }} }
        shell: bash
        run: |
          set -e
          target="\${{ steps.dates.outputs.target }}"
          gh api -H "Accept: application/vnd.github+json" /repos/murolem/wplace-archives/releases?per_page=100 > releases.json
          jq -r --arg d "$target" '
            .[] | .assets[] | select(.name | test($d) and test("\\\\.tar\\\\.gz"))
            | {name: .name, url: .browser_download_url}
          ' releases.json > assets.json
          if [ ! -s assets.json ]; then
            echo "skip=true" >> $GITHUB_OUTPUT
            exit 0
          fi
          jq -r '
            . as $a | $a.name as $n
            | ($n | sub("\\\\.tar\\\\.gz\\\\.(?:[a-z]{2}|\\\\d{3})$";"") | sub("\\\\.tar\\\\.gz$";"")) as $stem
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

      - name: Extract Saudi rectangle (z=11 x=1243..1253, y=875..904)
        if: steps.find.outputs.stem != ''
        shell: bash
        run: |
          set -e
          cd work
          target="\${{ steps.dates.outputs.target }}"
          mkdir -p "../tiles/tiles_$target"
          prefix=$(tar -tzf archive.tar.gz | head -1 | sed 's#/.*##')
          tar -tzf archive.tar.gz | awk -v p="$prefix" '
            match($0, "^" p "/([0-9]+)/([0-9]+)\\\\.png$", m) {
              x=m[1]; y=m[2];
              if (x>=1243 && x<=1253 && y>=875 && y<=904) print $0;
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
          target="\${{ steps.dates.outputs.target }}"
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
          git commit -m "Add tiles for \${{ steps.dates.outputs.target }}" || true
          git push
\`\`\`

---

## Regenerating snaps.json (after moves/cleanup)

\`\`\`powershell
# from repo root
$sn = Get-ChildItem -LiteralPath .\tiles -Directory | Sort-Object Name | ForEach-Object {
  $has = Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter *.png -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($has) { [pscustomobject]@{ label = ($_.Name -replace '^tiles_',''); dir = ('tiles/' + $_.Name) } }
}
$sn | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath .\snaps.json -Encoding UTF8
\`\`\`

---

## Troubleshooting

**Blank viewer:**
- Check that \`snaps.json\` exists and has valid entries
- Verify \`dir\` paths match actual folder names: \`"tiles/tiles_YYYY-MM-DD"\`
- Ensure PNG files exist in the date folders

**Missing tiles:**
- Run \`Sync-Tiles.ps1\` to detect and fill gaps
- Check that X range includes 1243-1253 (not just 1243-1250)

**GitHub Pages not updating:**
- Confirm pushes are landing on \`main\` branch
- Check repository Settings → Pages is set to "Deploy from branch: main / (root)"
- Wait 2-3 minutes for rebuild

**PowerShell errors:**
- Ensure you have PowerShell 7+ for parallel processing
- Check that \`tar\` or \`7z\` is available in PATH
- Verify \`GITHUB_TOKEN\` environment variable if hitting rate limits

---

## License

MIT
