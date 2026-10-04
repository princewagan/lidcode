# Gates: Lidcode provider dashboard and public download

OWNS: Sources/**, Tests/**, Script/**, .github/**, README.md, docs/**, GATES.md

Scope: Match OpenUsage 0.7.13's provider-card layout in Lidcode, let users add their own AI profiles, and publish a complete installable Mac download.

- [x] G1: Native app and provider behavior pass the Swift test suite.
  CHECK: swift test
  EXPECT: Executed
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/Users/princewagan/lidcode; path=faf417a81eb0/54 entries; output=local Swift suite exited 0; CI run 37185932008 independently executed 500 tests with 0 failures

- [x] G2: Release bundle and drag-to-Applications DMG are complete and signed.
  CHECK: bash Script/package-release.sh
  EXPECT: Release artifacts verified
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/Users/princewagan/lidcode; path=faf417a81eb0/54 entries; output=dist/LidCode.app: replacing existing signature | hdiutil: verify: checksum of "dist/Lidcode-0.2.0.dmg" is VALID

- [x] G3: Rendered dashboard and provider setup are checked against OpenUsage's versioned layout, in light and dark appearances.
  EVIDENCE: Native NSHostingView renders reviewed in /tmp/lidcode-ui-round-1, round-2 and /tmp/lidcode-ui-final; dashboard/customize/settings/empty in light and dark. Card width 320pt, gutter 14pt, radius 12pt, meters 5pt and Options footer match OpenUsage 0.7.13 source; supplied ZIP matches the versioned ProviderCard/Theme/HeaderView. Fixed left-meter direction and card fill after round 1. Full interactive desktop automation was unavailable (Computer Use timeout); visual checks used actual SwiftUI fixture renders. macOS 14 uses a material footer instead of macOS 26 Liquid Glass.

- [x] G4: GitHub contains the update and a downloadable release with setup instructions.
  EVIDENCE: main pushed; v0.2.0 published at https://github.com/princewagan/lidcode/releases/tag/v0.2.0 with DMG, ZIP and SHA256SUMS.txt. GitHub Actions run 37185932008 succeeded (500 tests, zero failures; signed bundle and DMG verified; publish passed). Downloaded CI assets to /tmp/lidcode-ci-release-verify: both SHA-256 checks passed; extracted bundle passed codesign --verify --deep --strict; bundled CLI reports 0.2.0. Repository remains private; broader public sharing awaits the user's visibility choice.
