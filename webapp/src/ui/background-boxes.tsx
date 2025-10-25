"use client";

import { motion } from "framer-motion";
import { cn } from "@/lib/utils";

type BoxesProps = {
  className?: string;
};

type AnimatedBox = {
  id: number;
  size: number;
  x: number;
  y: number;
  delay: number;
};

const seededValue = (seed: number) => {
  const result = Math.sin(seed) * 10000;
  return result - Math.floor(result);
};

const BOXES_PRESET: AnimatedBox[] = Array.from({ length: 45 }, (_, index) => {
  const size = 80 + Math.floor(seededValue(index + 1) * 140);
  const x = seededValue(index + 11) * 110 - 5;
  const y = seededValue(index + 31) * 110 - 5;
  const delay = seededValue(index + 61) * 6;
  return { id: index, size, x, y, delay };
});

export function Boxes({ className }: BoxesProps) {
  const boxes = BOXES_PRESET;

  return (
    <div className={cn("absolute inset-0 overflow-hidden", className)}>
      {boxes.map((box) => (
        <motion.div
          key={box.id}
          className="absolute rounded-lg border border-white/10 bg-white/[0.03] backdrop-blur-[2px]"
          style={{
            width: box.size,
            height: box.size,
            left: `${box.x}%`,
            top: `${box.y}%`,
          }}
          initial={{ opacity: 0, scale: 0.8 }}
          animate={{
            opacity: [0, 0.45, 0],
            scale: [0.8, 1.05, 0.8],
            rotate: [0, 1.5, -1.5, 0],
          }}
          transition={{
            duration: 8,
            repeat: Infinity,
            ease: "easeInOut",
            delay: box.delay,
          }}
        />
      ))}
    </div>
  );
}
