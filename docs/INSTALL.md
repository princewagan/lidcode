# Install Lidcode

Requires macOS 14 or later on Apple silicon (M1 or newer).

1. Download Lidcode's DMG from https://github.com/princewagan/lidcode/releases/latest.
2. Open the DMG and drag LidCode.app to Applications.
3. Open Lidcode from Applications. Its icon appears in the menu bar; the panel opens on first launch.

The public build is ad-hoc signed and is not notarized. If macOS blocks the first launch, use System Settings → Privacy & Security → Open Anyway after attempting to open it. If macOS offers no override, this Terminal command removes the downloaded app's quarantine flag:

    xattr -dr com.apple.quarantine /Applications/LidCode.app

Only use that command for the Lidcode download you intended to install. No Swift toolchain, Python, account with Lidcode, or source checkout is needed.

## Add your AI

Open the menu-bar panel → Options → Customize.

Lidcode detects default Claude Code and Codex CLI folders on first launch. You can add, edit, hide, or remove profiles. Choose Claude or Codex, optionally give the profile a name, and click Add. An empty folder field uses ~/.claude or ~/.codex. For a separate account, enter that CLI profile's folder; Codex expects the folder containing sessions/, not sessions/ itself. Claude's custom path must match CLAUDE_SECURESTORAGE_CONFIG_DIR.

Sign in through the corresponding CLI first. Lidcode reads that existing login; it does not ask you to paste API keys or passwords. Claude limits come from the account's usage endpoint. If Claude's login expires, use Claude Code to sign in again. Codex limits come from local CLI session logs: run a session to produce a reading. A Codex app-only login without those logs will show No usage yet.

Refresh by clicking the footer's update line or pressing Command-R. Usage refreshes every five minutes. Click a percentage to switch between left and used; click a reset label to switch between a countdown and a date. Old readings are marked Outdated. Missing readings say Unavailable rather than showing zero usage.

This release supports Claude and Codex usage profiles. Other assistants can still participate in Lidcode's existing process watching and CLI work leases.

## Keep your Mac awake

Use the dashboard's keep-awake button and duration slider. Closed-lid protection additionally needs the bundled helper. Click Install in the panel to authorize its installation once; regular keep-awake works without it.

Battery and heat protections remain active. Use a hard, ventilated surface when the lid is closed. The helper reverts the system sleep setting if Lidcode disconnects or stops heartbeating.

## Optional command line

Options → Settings → Install lidcode command creates ~/.local/bin/lidcode pointing to the bundled CLI. If that folder is not already on your PATH, add this line to ~/.zshrc:

    export PATH="$HOME/.local/bin:$PATH"

Open a new Terminal and run:

    lidcode --version
    lidcode doctor

## Update or remove

Options → Check for updates opens the latest GitHub release. Quit Lidcode, download the new DMG, and replace the app in Applications. AI profiles and settings are retained in ~/.lidcode. Updates are manual in this release.

To remove the optional privileged helper, use Script/uninstall-helper.sh from the repository. Then quit Lidcode and move the app to Trash. If you installed the CLI link, remove ~/.local/bin/lidcode. The native collector does not install a background LaunchAgent.

Legacy users who installed Script/install-usage-agent.sh can keep it, but the app's native snapshot takes precedence. The script remains available for compatibility and now reads the same AI profile configuration.

## Verify the download

Download SHA256SUMS.txt alongside the DMG/ZIP, put them in the same folder, and run:

    shasum -a 256 -c SHA256SUMS.txt

## Credits

The provider-card layout and marks are adapted from OpenUsage 0.7.13 (https://github.com/robinebers/openusage), Copyright 2026 Robin Ebers, under the MIT license. The full license is included inside the app and in docs/OpenUsage-LICENSE.txt.
