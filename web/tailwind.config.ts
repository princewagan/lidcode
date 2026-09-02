import type { Config } from "tailwindcss";

/**
 * Warp Monitor design tokens.
 *
 * The app is a terminal companion, so it is dark-only by design (see
 * app/globals.css `color-scheme: dark`). Because there is no light theme we can
 * name surfaces by elevation instead of shipping `dark:` variants everywhere.
 *
 * Palette rationale — mirrors Warp's chrome: near-black page, barely-raised
 * panels, hairline borders, and colour reserved exclusively for status.
 * Every foreground token was contrast-checked against `ink.1` (#0e1013):
 *   fg       #e6e8ec  → 15.9:1
 *   fg.muted #9ba3af  →  7.5:1
 *   fg.dim   #7b8390  →  5.0:1
 * All clear WCAG 2.1 AA for normal text.
 */
const config: Config = {
  darkMode: "class",
  content: [
    "./pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./components/**/*.{js,ts,jsx,tsx,mdx}",
    "./app/**/*.{js,ts,jsx,tsx,mdx}",
    "./lib/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        // Surface stack, lowest → highest elevation.
        ink: {
          0: "#07080a", // page
          1: "#0e1013", // card
          2: "#15181c", // header / raised panel
          3: "#1c2026", // hover / inline chip
        },
        // Hairline borders. Warp separates with light, not shadow.
        line: {
          DEFAULT: "#22262d",
          soft: "#191d22",
        },
        fg: {
          DEFAULT: "#e6e8ec",
          muted: "#9ba3af",
          dim: "#7b8390",
        },
        // Warp shows a light-blue dot on tabs whose output you have not read.
        unseen: "#7dd3fc",
      },
      fontFamily: {
        sans: [
          "-apple-system",
          "BlinkMacSystemFont",
          "SF Pro Text",
          "Segoe UI",
          "Roboto",
          "system-ui",
          "sans-serif",
        ],
        // Paths, branches, timestamps and ids render in mono — the single
        // strongest signal that this is a terminal tool.
        mono: [
          "ui-monospace",
          "SFMono-Regular",
          "SF Mono",
          "Menlo",
          "Consolas",
          "Liberation Mono",
          "monospace",
        ],
      },
      keyframes: {
        // Expanding halo around a live status dot.
        halo: {
          "0%": { transform: "scale(1)", opacity: "0.55" },
          "70%, 100%": { transform: "scale(2.4)", opacity: "0" },
        },
        breathe: {
          "0%, 100%": { opacity: "1" },
          "50%": { opacity: "0.45" },
        },
        "slide-down": {
          from: { opacity: "0", transform: "translateY(-4px)" },
          to: { opacity: "1", transform: "translateY(0)" },
        },
      },
      animation: {
        halo: "halo 2s cubic-bezier(0, 0, 0.2, 1) infinite",
        breathe: "breathe 2.4s ease-in-out infinite",
        "slide-down": "slide-down 140ms ease-out",
      },
    },
  },
  plugins: [],
};

export default config;
