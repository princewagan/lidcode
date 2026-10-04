import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "LidCode",
  description: "Your Mac's lid, battery, thermals and agent sessions.",
  manifest: "/manifest.webmanifest",
  icons: {
    icon: "/icon-192.png",
    apple: "/apple-touch-icon.png",
  },
  appleWebApp: {
    capable: true,
    statusBarStyle: "black-translucent",
    title: "LidCode",
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  viewportFit: "cover",
  themeColor: "#000000",
  colorScheme: "dark",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  // `dark` is pinned on <html>: this is a dark-only app.
  // `.lc-scope` activates the LidCode CSS tokens and the html/body #000 override
  // in app/globals.css (the `:has(.lc-scope)` rule).
  return (
    <html lang="en" className="dark">
      <body className="font-sans">
        <div className="lc-scope">{children}</div>
      </body>
    </html>
  );
}
