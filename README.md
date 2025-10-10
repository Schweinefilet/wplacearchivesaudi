# wplace-archive-tools

**Wplace Archive Viewer for Mecca + Medina** — static site + scripts that download, join, and trim daily world dumps to a small z=11 rectangle over western Saudi Arabia, then publish a browsable timeline.

**Live site:** https://schweinefilet.github.io/wplacearchivesaudi/

> Built for **Mecca + Medina** archiving purposes on wplace.live for **islamwp**.  
> Archives are taken from **https://github.com/murolem/wplace-archives**.

---

## What this repo contains

- **`index.html`** — Leaflet viewer that fetches `snaps.json` and overlays day folders; timeline scrub, HUD, prev/next keys, and quick 4K exports.
- **`snaps.json`** — array of objects:  
  `[{ "label": "YYYY-MM-DD", "dir": "tiles/tiles_YYYY-MM-DD" }, …]`
- **`tiles/tiles_YYYY-MM-DD/{x}/{y}.png`** — trimmed z=11 tiles for the Saudi rectangle (x=1243…1258, y=875…904).
- **Scripts** (Windows-focused):
  - `Get-LatestWplaceReleases.ps1/.bat` — pull the **latest** dump per day (handles split parts).
  - `Make-JoinedTars.ps1` — join parts (resume-safe), verify, **trim** to the rectangle, export `tiles_YYYY-MM-DD`.
  - `Publish-Site.ps1/.bat` — mirror new `tiles_*` into `/tiles/`, rebuild `snaps.json`, commit, push.
- (Optional) **GitHub Actions** workflow to run the whole thing on GitHub daily (no PC needed).

---

## Coordinates & zoom

- **Zoom:** 11  
- **Rectangle:** `x = 1243…1258`, `y = 875…904`  
Covers Mecca, Medina, Jeddah, Taif at z=11.

---

## Directory layout

```

/ (repo root)
├─ index.html
├─ snaps.json
├─ tiles/
│  ├─ tiles_2025-10-09/
│  │  └─ 1257/883.png … 1258/904.png
│  └─ tiles_YYYY-MM-DD/…
├─ Get-LatestWplaceReleases.ps1
├─ Make-JoinedTars.ps1
├─ Publish-Site.ps1
└─ .github/workflows/ (optional)

````

---

## Quick start (Windows, local)

1) **Download latest-per-day assets** into your staging folder:
```powershell
# Optional: higher API rate limits
[Environment]::SetEnvironmentVariable("GITHUB_TOKEN","<your_token>","User")
$env:GITHUB_TOKEN = "<your_token>"

# Download (adjust inside the script if needed)
.\Get-LatestWplaceReleases.bat
````

2. **Join + Extract** (resume-safe; trims to the rectangle; cleans up on full success):

```powershell
.\Run-Joiner.bat
# Resulting tiles end up in: E:\wplace-archive\tiles_YYYY-MM-DD\{x}\{y}.png
```

3. **Publish the site** (mirrors tiles to `/tiles`, rebuilds `snaps.json`, commits, pushes):

```powershell
.\Publish-Site.bat
```

4. **View locally** (optional):

```powershell
# from repo root
python -m http.server 8000
# then open:
# http://localhost:8000/
```

---

## Auto-updates (choose one)

### A) Windows Task Scheduler (PC must be on)

Schedule the **publish** step daily:

```powershell
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
```

> Make sure the account running the task has working Git credentials (Git Credential Manager).

### B) GitHub Actions (no PC needed)

Create `.github/workflows/publish.yml` in this repo to auto-fetch the next date’s latest dump from `murolem/wplace-archives`, extract the rectangle into `tiles/tiles_YYYY-MM-DD`, update `snaps.json`, and push. Example workflow:

```yaml
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

MIT.

