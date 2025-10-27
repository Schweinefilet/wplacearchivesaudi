"use client";
/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable react-hooks/unsupported-syntax */

import { useEffect, useRef } from "react";
import L from "leaflet";

const TRANSPARENT_TILE = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==";
const OVERLAY_ZOOM = 11;
const THEME_KEY = "wplace-viewer-theme";

export function ArchiveViewer() {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const mapRef = useRef<L.Map | null>(null);

  useEffect(() => {
    const root = rootRef.current;
    if (!root) return;

    const mapContainer = root.querySelector<HTMLDivElement>("#map");
    if (!mapContainer) return;

    const elements = {
      body: document.body,
      timelineLabel: root.querySelector<HTMLDivElement>("#timelineLabel"),
      timelineSlider: root.querySelector<HTMLInputElement>("#timelineSlider"),
      timelinePrev: root.querySelector<HTMLButtonElement>("#timelinePrev"),
      timelineNext: root.querySelector<HTMLButtonElement>("#timelineNext"),
      currentLabel: root.querySelector<HTMLSpanElement>("#currentLabel"),
      currentZoom: root.querySelector<HTMLSpanElement>("#currentZoom"),
      currentRegion: root.querySelector<HTMLSpanElement>("#currentRegion"),
      currentPosition: root.querySelector<HTMLSpanElement>("#currentPosition"),
      currentBadge: root.querySelector<HTMLSpanElement>("#currentBadge"),
      btnAbout: root.querySelector<HTMLButtonElement>("#btnAbout"),
      btnMecca: root.querySelector<HTMLButtonElement>("#btnMecca"),
      btnMedina: root.querySelector<HTMLButtonElement>("#btnMedina"),
      btnToggleHUD: root.querySelector<HTMLButtonElement>("#btnToggleHUD"),
      btnTheme: root.querySelector<HTMLButtonElement>("#btnTheme"),
      btnOpenLive: root.querySelector<HTMLButtonElement>("#btnOpenLive"),
      btnExport: root.querySelector<HTMLButtonElement>("#btnExport"),
      exportPanel: root.querySelector<HTMLDivElement>("#exportPanel"),
      exportMenu: root.querySelector<HTMLDivElement>("#exportMenu"),
      aboutModal: root.querySelector<HTMLDivElement>("#aboutModal"),
      closeAbout: root.querySelector<HTMLButtonElement>("#closeAbout"),
      frame: root.querySelector<HTMLDivElement>("#frame"),
    };

    const state = {
      snaps: [] as Array<{ label: string; dir: string }>,
      index: 0,
      currentDir: "",
      currentRegion: "World",
      overlay: null as L.TileLayer | null,
      isHudHidden: false,
    };

    const handlers: Array<() => void> = [];

    const initTheme = () => {
      const saved = typeof window !== "undefined" ? localStorage.getItem(THEME_KEY) : null;
      const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
      const initial = saved === "dark" || saved === "light" ? saved : prefersDark ? "dark" : "light";
      setTheme(initial);
    };

    const setTheme = (theme: string) => {
      const next = theme === "dark" ? "dark" : "light";
      elements.body.dataset.theme = next;
      localStorage.setItem(THEME_KEY, next);
      if (elements.btnTheme) {
        elements.btnTheme.textContent = next === "dark" ? "Light Mode" : "Dark Mode";
      }
    };

    const detectMobile = () => {
      const isMobile = /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent) ||
        (navigator.maxTouchPoints && navigator.maxTouchPoints > 2) ||
        window.innerWidth <= 768;
      elements.body.classList.toggle("is-mobile", isMobile);
    };

    const map = L.map(mapContainer, {
      minZoom: 7,
      maxZoom: 14,
      zoomSnap: 0.25,
      zoomDelta: 0.25,
      scrollWheelZoom: true,
      zoomControl: false,
      fadeAnimation: false,
      preferCanvas: false,
    }).setView([21.422487, 39.826206], 11.5);
    mapRef.current = map;

    const gridProto = L.GridLayer.prototype as any;
    if (!gridProto.__wplacePatched) {
      const originalInitTile = gridProto._initTile as (tile: HTMLImageElement) => void;
      gridProto._initTile = function initTile(this: any, tile: HTMLImageElement) {
        originalInitTile.call(this, tile);
        const size = this.getTileSize();
        tile.setAttribute("width", String(size.x + 4));
        tile.setAttribute("height", String(size.y + 4));
        tile.style.width = `${size.x + 4}px`;
        tile.style.height = `${size.y + 4}px`;
        tile.style.margin = "-2px";
        tile.style.willChange = "transform";
        tile.style.imageRendering = "pixelated";
        tile.style.backfaceVisibility = "hidden";
        tile.style.transform = "translate3d(0,0,0)";
        if ((tile as any)._tilePos) {
          (tile as any)._tilePos._round();
          L.DomUtil.setPosition(tile, (tile as any)._tilePos);
        }
      };
      gridProto.__wplacePatched = true;
    }

    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19,
      attribution: "© OpenStreetMap contributors",
    }).addTo(map);

    state.overlay = L.tileLayer(TRANSPARENT_TILE, {
      tileSize: 256,
      minZoom: 7,
      maxZoom: 14,
      minNativeZoom: OVERLAY_ZOOM,
      maxNativeZoom: OVERLAY_ZOOM,
      keepBuffer: 8,
      updateWhenZooming: true,
      updateWhenIdle: false,
      errorTileUrl: TRANSPARENT_TILE,
    }).addTo(map);

    const syncSliderBounds = () => {
      if (!elements.timelineSlider) return;
      const max = Math.max(0, state.snaps.length - 1);
      elements.timelineSlider.min = "0";
      elements.timelineSlider.max = String(max);
      elements.timelineSlider.step = "1";
      elements.timelineSlider.disabled = state.snaps.length <= 1;
    };

    const updateSliderUI = () => {
      if (!elements.timelineSlider || !elements.timelineLabel) return;
      elements.timelineSlider.value = String(state.index);
      const snap = state.snaps[state.index];
      const labelText = snap ? snap.label : "Snapshot";
      elements.timelineLabel.textContent = `${labelText} · ${state.index + 1} / ${state.snaps.length}`;
      if (elements.timelinePrev) elements.timelinePrev.disabled = state.index <= 0;
      if (elements.timelineNext) elements.timelineNext.disabled = state.index >= state.snaps.length - 1;
    };

    const setHudHidden = (next: boolean) => {
      state.isHudHidden = !!next;
      elements.body.classList.toggle("hud-hidden", state.isHudHidden);
      if (elements.btnToggleHUD) {
        elements.btnToggleHUD.setAttribute("aria-pressed", state.isHudHidden ? "true" : "false");
      }
    };

    const updateMeta = () => {
      const snap = state.snaps[state.index];
      if (elements.currentLabel) elements.currentLabel.textContent = snap ? snap.label : "—";
      if (elements.currentZoom) elements.currentZoom.textContent = `Z ${map.getZoom().toFixed(2)}`;
      if (elements.currentRegion) elements.currentRegion.textContent = state.currentRegion;
      if (elements.currentPosition) elements.currentPosition.textContent = `${state.index + 1} / ${state.snaps.length}`;
      if (elements.currentBadge) elements.currentBadge.classList.toggle("hidden", state.index !== state.snaps.length - 1);
      document.title = `${snap ? `${snap.label} - ` : ""}WPlace Archive Viewer`;
      updateSliderUI();
    };

    const setSnap = (n: number) => {
      if (!Array.isArray(state.snaps) || !state.snaps.length) return;
      const clamped = Math.max(0, Math.min(state.snaps.length - 1, Math.round(n)));
      state.index = clamped;
      const snap = state.snaps[state.index] || null;
      state.currentDir = snap && snap.dir ? snap.dir : "";
      if (state.currentDir && state.overlay) {
        state.overlay.setUrl(`${state.currentDir}/{x}/{y}.png`);
      } else if (state.overlay) {
        state.overlay.setUrl(TRANSPARENT_TILE);
      }
      updateMeta();
    };

    const stepSnap = (d: number) => setSnap(state.index + d);

    const openAbout = () => {
      if (elements.aboutModal) elements.aboutModal.classList.remove("hidden");
    };

    const closeAbout = () => {
      if (elements.aboutModal) elements.aboutModal.classList.add("hidden");
    };

    const bind = <T extends HTMLElement | Document | Window>(
      target: T,
      type: string,
      handler: (event: any) => void,
      options?: boolean | AddEventListenerOptions,
    ) => {
      target.addEventListener(type as any, handler as any, options as any);
      handlers.push(() => target.removeEventListener(type as any, handler as any, options as any));
    };

    bind(document, "click", (event: MouseEvent) => {
      if (elements.exportMenu && !elements.exportMenu.contains(event.target as Node)) {
        elements.exportPanel?.classList.add("hidden");
      }
      if (elements.aboutModal && !elements.aboutModal.classList.contains("hidden")) {
        const dialog = elements.aboutModal.querySelector<HTMLDivElement>(".modal-dialog");
        if (dialog && !dialog.contains(event.target as Node) && event.target !== elements.btnAbout) {
          closeAbout();
        }
      }
    });

    if (elements.btnExport && elements.exportPanel) {
      bind(elements.btnExport, "click", (e: MouseEvent) => {
        e.stopPropagation();
        elements.exportPanel?.classList.toggle("hidden");
      });
    }

    if (elements.btnAbout) bind(elements.btnAbout, "click", openAbout);
    if (elements.closeAbout) bind(elements.closeAbout, "click", closeAbout);
    if (elements.aboutModal) {
      bind(elements.aboutModal, "click", (ev: MouseEvent) => {
        if (ev.target === elements.aboutModal) closeAbout();
      });
    }

    if (elements.timelineSlider) {
      bind(elements.timelineSlider, "input", (ev: Event) => {
        const idx = Number((ev.target as HTMLInputElement).value);
        if (!Number.isNaN(idx)) setSnap(idx);
      });
    }

    if (elements.timelinePrev) bind(elements.timelinePrev, "click", () => stepSnap(-1));
    if (elements.timelineNext) bind(elements.timelineNext, "click", () => stepSnap(1));

    if (elements.btnTheme) {
      bind(elements.btnTheme, "click", () => {
        const cur = elements.body.dataset.theme === "dark" ? "dark" : "light";
        setTheme(cur === "dark" ? "light" : "dark");
      });
    }

    if (elements.btnOpenLive) {
      bind(elements.btnOpenLive, "click", () => {
        const center = map.getCenter();
        const zoom = map.getZoom();
        const targetUrl = `https://wplace.live/?lat=${center.lat.toFixed(5)}&lng=${center.lng.toFixed(5)}&zoom=${Math.max(
          zoom,
          10.61,
        ).toFixed(2)}`;
        window.open(targetUrl, "_blank", "noopener");
      });
    }

    if (elements.btnMecca) {
      bind(elements.btnMecca, "click", () => {
        state.currentRegion = "Mecca";
        map.fitBounds(L.latLngBounds([21.3, 39.676], [21.545, 39.976]), { padding: [40, 40] });
        updateMeta();
      });
    }

    if (elements.btnMedina) {
      bind(elements.btnMedina, "click", () => {
        state.currentRegion = "Medina";
        map.fitBounds(L.latLngBounds([24.3497, 39.37], [24.6997, 39.979]), { padding: [40, 40] });
        updateMeta();
      });
    }

    if (elements.btnToggleHUD) {
      bind(elements.btnToggleHUD, "click", () => setHudHidden(!state.isHudHidden));
    }

    const onKeyDown = (ev: KeyboardEvent) => {
      const tag = (document.activeElement && (document.activeElement as HTMLElement).tagName) || "";
      if (["INPUT", "TEXTAREA", "SELECT"].includes(tag)) return;
      const key = ev.key.toLowerCase();
      if (key === "," || ev.key === "ArrowLeft") {
        ev.preventDefault();
        stepSnap(-1);
      }
      if (key === "." || ev.key === "ArrowRight") {
        ev.preventDefault();
        stepSnap(1);
      }
      if (key === "h") {
        ev.preventDefault();
        setHudHidden(!state.isHudHidden);
      }
      if (key === "f") {
        ev.preventDefault();
        elements.frame?.classList.toggle("hidden");
      }
      if (key === "escape" && elements.aboutModal && !elements.aboutModal.classList.contains("hidden")) {
        ev.preventDefault();
        closeAbout();
      }
    };
    bind(document, "keydown", onKeyDown);

    const frameState: { drag: null | { startX: number; startY: number; base: DOMRect; id: number } } = {
      drag: null,
    };

    const getFrameRect = () => {
      if (!elements.frame) return new DOMRect();
      const style = getComputedStyle(elements.frame);
      return new DOMRect(
        parseInt(style.left, 10) || 0,
        parseInt(style.top, 10) || 0,
        parseInt(style.width, 10) || 0,
        parseInt(style.height, 10) || 0,
      );
    };

    const setFrameRect = (rect: { x: number; y: number; w: number; h: number }) => {
      if (!elements.frame) return;
      const box = map.getContainer().getBoundingClientRect();
      const next = { ...rect };
      next.w = Math.max(60, Math.min(next.w, box.width));
      next.h = Math.max(60, Math.min(next.h, box.height));
      next.x = Math.max(0, Math.min(next.x, box.width - next.w));
      next.y = Math.max(0, Math.min(next.y, box.height - next.h));
      elements.frame.style.left = `${next.x}px`;
      elements.frame.style.top = `${next.y}px`;
      elements.frame.style.width = `${next.w}px`;
      elements.frame.style.height = `${next.h}px`;
    };

    const initFrame = () => {
      if (!elements.frame) return;
      const rect = map.getContainer().getBoundingClientRect();
      const width = Math.min(Math.floor(rect.width * 0.55), 900);
      const height = Math.floor((width * 9) / 16);
      const x = Math.round((rect.width - width) / 2);
      const y = Math.round((rect.height - height) / 2);
      setFrameRect({ x, y, w: width, h: height });
    };

    if (elements.frame) {
      bind(elements.frame, "pointerdown", (e: PointerEvent) => {
        e.preventDefault();
        elements.frame?.setPointerCapture(e.pointerId);
        const rect = getFrameRect();
        frameState.drag = {
          startX: e.clientX,
          startY: e.clientY,
          base: new DOMRect(rect.x, rect.y, rect.width, rect.height),
          id: e.pointerId,
        };
      });
    }

    bind(window, "pointermove", (e: PointerEvent) => {
      if (!frameState.drag) return;
      const dx = e.clientX - frameState.drag.startX;
      const dy = e.clientY - frameState.drag.startY;
      setFrameRect({
        x: frameState.drag.base.x + dx,
        y: frameState.drag.base.y + dy,
        w: frameState.drag.base.width,
        h: frameState.drag.base.height,
      });
    });

    bind(window, "pointerup", (e: PointerEvent) => {
      if (frameState.drag && e.pointerId === frameState.drag.id) {
        frameState.drag = null;
      }
    });

    bind(window, "resize", () => {
      detectMobile();
      initFrame();
    });

    map.on("zoom zoomend moveend", updateMeta);

    handlers.push(() => map.off("zoom zoomend moveend", updateMeta));

    const loadSnaps = async () => {
      try {
        const res = await fetch("/snaps.json", { cache: "no-store" });
        if (res.ok) {
          const data = await res.json();
          if (Array.isArray(data) && data.length) {
            state.snaps = data;
          }
        }
      } catch (err) {
        console.error("Failed to load snaps.json", err);
      }
      if (!Array.isArray(state.snaps) || state.snaps.length === 0) {
        state.snaps = [{ label: "Snapshot", dir: "" }];
      }
      syncSliderBounds();
      setSnap(state.snaps.length - 1);
      initFrame();
    };

    initTheme();
    detectMobile();
    setHudHidden(state.isHudHidden);
    openAbout();
    loadSnaps();

    return () => {
      handlers.forEach((fn) => fn());
      if (mapRef.current) {
        mapRef.current.remove();
        mapRef.current = null;
      }
    };
  }, []);

  return (
    <section ref={rootRef} className="archive-viewer h-full w-full">
      <div id="map" className="map-canvas" />

      <div id="frame" className="frame hidden">
        <div className="frame-badge">Drag to reposition · F toggles visibility</div>
      </div>

      <div className="control-stack">
        <div className="control-row">
          <button id="btnAbout" className="chip" type="button">
            About
          </button>
          <div className="meta-pill" id="currentMeta" role="status" aria-live="polite">
            <span id="currentLabel">—</span>
            <span className="meta-divider">·</span>
            <span id="currentZoom">Z 0.00</span>
            <span className="meta-divider">·</span>
            <span id="currentRegion">World</span>
            <span className="meta-divider">·</span>
            <span id="currentPosition">1 / 1</span>
            <span id="currentBadge" className="meta-badge hidden">
              Latest
            </span>
          </div>
        </div>
        <div className="control-row">
          <button id="btnMecca" className="chip chip-ghost" type="button">
            Mecca
          </button>
          <button id="btnMedina" className="chip chip-ghost" type="button">
            Medina
          </button>
          <button id="btnToggleHUD" className="chip chip-ghost" type="button">
            Toggle HUD (H)
          </button>
        </div>
      </div>

      <div className="control-stack right">
        <div className="control-row">
          <div className="menu" id="exportMenu">
            <button id="btnExport" className="chip" type="button">
              Export
            </button>
            <div id="exportPanel" className="menu-panel hidden" role="menu">
              <button id="save4kMecca" type="button">
                4K Mecca
              </button>
              <button id="save4kMedina" type="button">
                4K Medina
              </button>
              <button id="save4kFrame" type="button">
                4K Selected Frame
              </button>
            </div>
          </div>
          <button id="btnTheme" className="chip" type="button" aria-pressed="true">
            Light Mode
          </button>
          <button id="btnOpenLive" className="chip" type="button">
            Open Live
          </button>
        </div>
      </div>

      <div className="bottom-bar" id="timelineWrapper">
        <div className="slider-label" id="timelineLabel">
          Snapshot 1 / 1
        </div>
        <div className="slider-controls">
          <button id="timelinePrev" className="chip chip-ghost" type="button" aria-label="Previous snapshot">
            ➤
          </button>
          <div className="slider-wrap">
            <input type="range" id="timelineSlider" min="0" max="0" value="0" aria-label="Snapshot position" />
          </div>
          <button id="timelineNext" className="chip chip-ghost" type="button" aria-label="Next snapshot">
            ➤
          </button>
        </div>
      </div>

      <div className="modal hidden" id="aboutModal" role="dialog" aria-modal="true" aria-labelledby="aboutTitle">
        <div className="modal-dialog">
          <button className="modal-close" type="button" id="closeAbout" aria-label="Close dialog">
            &times;
          </button>
          <h2 id="aboutTitle">Hello and welcome</h2>
          <p>This archive only includes Western Saudi Arabia due to space limitations.</p>
          <p>GUIDE:</p>
          <ul>
            <li>Drag the map or use the mouse wheel / pinch to pan and zoom.</li>
            <li>Scrub the slider or tap <kbd>,</kbd> / <kbd>.</kbd> (or arrow keys) to move through available snapshots.</li>
            <li>Jump to key regions with the Mecca and Medina buttons.</li>
            <li>Press <kbd>H</kbd> or use “Toggle HUD” to hide the interface for clean screenshots.</li>
            <li>Press <kbd>F</kbd> to show or hide the draggable export frame; reposition it to capture a crop.</li>
            <li>Open the Export menu to save 4K composites of Mecca, Medina, or the selected frame.</li>
            <li>Use the Theme toggle to switch between dark and light backgrounds.</li>
          </ul>
          <p>You can close this guide with the × button or by clicking the shaded backdrop.</p>
          <div className="modal-actions">
            <a href="README.md" target="_blank" rel="noopener">
              Project README
            </a>
          </div>
        </div>
      </div>
    </section>
  );
}
