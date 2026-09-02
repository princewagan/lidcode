/**
 * app/manifest.ts
 *
 * PWA manifest — enables "Add to Home Screen" on iOS and Android.
 */

import type { MetadataRoute } from "next";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "LidCode",
    short_name: "LidCode",
    description: "Your Mac's lid, battery, thermals and agent sessions.",
    start_url: "/",
    display: "standalone",
    background_color: "#000000",
    theme_color: "#000000",
    icons: [
      {
        src: "/icon-192.png",
        sizes: "192x192",
        type: "image/png",
      },
      {
        src: "/icon-512.png",
        sizes: "512x512",
        type: "image/png",
      },
    ],
  };
}
