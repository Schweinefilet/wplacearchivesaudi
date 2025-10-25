"use client";

import React from "react";
import { Boxes } from "@/ui/background-boxes";
import { cn } from "@/lib/utils";

export function BackgroundBoxesDemo() {
  return (
    <div className="relative w-full overflow-hidden bg-slate-950 flex flex-col items-center justify-center rounded-none border-b border-white/5 h-[24rem]">
      <div className="absolute inset-0 w-full h-full bg-slate-900 z-20 [mask-image:radial-gradient(transparent,white)] pointer-events-none" />
      <Boxes />
      <h1 className={cn("md:text-5xl text-2xl text-white font-semibold tracking-tight relative z-20")}>WPlace Archive Viewer</h1>
      <p className="text-center mt-3 max-w-2xl text-neutral-300 relative z-20">
        Explore high-resolution snapshots of Western Saudi Arabia. Scrub the timeline, export 4K composites, and compare regions with a Leaflet-powered interface.
      </p>
    </div>
  );
}
