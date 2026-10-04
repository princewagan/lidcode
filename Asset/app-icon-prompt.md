# LidCode app icon

Deterministic vector artwork rendered with AppKit by `Script/makebrand.swift`.

A silver MacBook lid viewed from behind, with a slim base lip and hinge detail,
on a blue face matching `AppTheme.blue` (RGB 0.29, 0.49, 0.79, approximately
`#4A7DC9`). Subtle aluminium shading and a contact shadow give the lid depth.
The native 1024px canvas uses a centred 824px rounded plate with transparent
margins. Web and Apple touch exports use a full-bleed face so each platform
can apply its own mask.

Regenerate all assets with `bash Script/make-asset.sh`.

- Native master: `Asset/app-icon.png`
- macOS: `Resource/LidCode.icns`
- Banner: `Asset/banner.png`
- Web: `web/public/icon-192.png`, `web/public/icon-512.png`
- Apple touch icon: `web/public/apple-touch-icon.png`
