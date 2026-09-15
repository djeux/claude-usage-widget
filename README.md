# Claude Usage

A macOS menu bar app that shows how much of your Claude subscription limits
(Pro/Max) you've used — the same percentages Claude Code's `/usage` command
reports, always one glance away.

## What it shows

- **Menu bar:** `✽ 62%` — the most-constrained limit right now. Orange at
  ≥60%, red at ≥95%, dimmed when the data is stale.
- **Dropdown:** every limit window your plan reports (5-hour session,
  weekly all-models, weekly per-model such as Opus, Sonnet, or Fable) with a
  progress bar and reset time,
  plus last-updated time, manual refresh, a launch-at-login toggle, and Quit.

## Requirements

- macOS 14 (Sonoma) or later
- A Claude subscription (Pro/Max). Claude Code does not need to be installed.

## Install

1. Download the latest `ClaudeUsage-*.pkg` from
   [Releases](https://github.com/djeux/claude-usage-widget/releases).
2. The package isn't notarized yet, so macOS will warn on open:
   right-click the `.pkg` → Open → Open (or allow it under
   System Settings → Privacy & Security → "Open Anyway").
3. Open the menu bar item and click **Sign in**. Approve in the browser;
   the app finishes signing in on its own. No keychain prompts.

## How it works / privacy

- Signs in with your Claude account through the same OAuth login Claude
  Code uses, asking only for the `user:profile` scope — the app cannot
  run inference with its token.
- Stores its own tokens in a keychain item it creates (`Claude Usage`),
  so macOS never asks you to allow access. It never reads Claude Code's
  keychain item.
- Talks only to `claude.com` / `platform.claude.com` (sign-in and token
  refresh) and `https://api.anthropic.com/api/oauth/usage` (the same
  endpoint Claude Code's `/usage` uses), every 5 minutes.
- No analytics, no third-party servers, no dependencies.
- If Anthropic rejects the token, the app shows **Sign in** again; if the
  network is down it dims the last data and retries.

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
