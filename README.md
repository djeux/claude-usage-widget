# Claude Usage

A macOS menu bar app that shows how much of your Claude subscription limits
(Pro/Max) you've used — the same percentages Claude Code's `/usage` command
reports, always one glance away.

## What it shows

- **Menu bar:** `✽ 62%` — the most-constrained limit right now. Orange at
  ≥60%, red at ≥95%, dimmed when the data is stale.
- **Dropdown:** every limit window your plan reports (5-hour session,
  weekly all-models, weekly per-model) with a progress bar and reset time,
  plus last-updated time, manual refresh, a launch-at-login toggle, and Quit.

## Requirements

- macOS 14 (Sonoma) or later
- [Claude Code](https://claude.com/claude-code) installed and logged in
  with a Claude subscription — the app reads the OAuth token Claude Code
  stores in your keychain

## Install

1. Download the latest `ClaudeUsage-*.pkg` from
   [Releases](https://github.com/djeux/claude-usage-widget/releases).
2. The package isn't notarized yet, so macOS will warn on open:
   right-click the `.pkg` → Open → Open (or allow it under
   System Settings → Privacy & Security → "Open Anyway").
3. On first launch, macOS asks for keychain access to
   `Claude Code-credentials` → click **Always Allow** so background
   refresh keeps working.

## How it works / privacy

- Reads the access token from your login keychain **read-only** — it never
  touches the refresh token and never writes to the keychain.
- Talks only to `https://api.anthropic.com/api/oauth/usage` (the same
  endpoint Claude Code's `/usage` uses), every 5 minutes.
- No analytics, no third-party servers, no dependencies.
- If the token expires, the app dims the last data and recovers
  automatically the next time you use Claude Code (which refreshes the
  token in the keychain).

## Build from source

Requires Xcode 26+.

```bash
git clone https://github.com/djeux/claude-usage-widget.git
cd claude-usage-widget
swift test --package-path ClaudeUsageCore                                  # unit tests
xcodebuild -project "Claude Usage.xcodeproj" -scheme "Claude Usage" build  # app
```

## Note

This is an unofficial tool, not affiliated with Anthropic. The usage
endpoint is the one Claude Code itself uses but isn't a documented public
API — if it changes, the app degrades gracefully (keeps the last data and
shows a status line).
