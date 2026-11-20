# AgentNudge

A lightweight macOS menu bar utility for scheduling prompts (like `"continue"`) to be typed and submitted into AI agents (`claude`, `agy`, `codex`, `Claude.app`, VS Code, etc.) when usage limits renew.

## Features

- **Smart Target Detection:** Automatically discovers active AI CLI sessions in `Terminal.app` tabs (`claude`, `agy`, `codex`, `gemini`, `aider`, `goose`, `opencode`, `amp`) along with their working directory, plus any other Terminal tab, running Mac GUI app, or the currently focused window.
- **Countdown & Exact Clock Scheduling:** Schedule via quick presets (`15m`, `30m`, `1h`, `2h`, `3h`, `5h`), custom hours/minutes, or an exact wall-clock time (`HH:mm`, auto-rolling to tomorrow if earlier than now).
- **Multiple Simultaneous Timers:** Run independent timers for multiple agent sessions concurrently, with live menu bar countdown (`HH:mm:ss` / `(+N)`), pause/resume, `+5m`, and instant send.
- **Keeps Mac Awake While Armed:** Uses `IOPMAssertion` (`PreventUserIdleDisplaySleep`) when enabled so timers don't get stalled behind a locked/sleeping screen. If the screen is manually locked, due nudges queue automatically and fire upon unlock.
- **Focus Snapshot & Restore:** Checks for recent typing so it won't interrupt mid-word, focuses the exact Terminal tab by TTY (or target Mac app), types your message + Return, and restores your previous app / Terminal tab afterward.

## Build & Install

```bash
./scripts/build_app.sh
```

This compiles `AgentNudge` in release mode, generates `AppIcon.icns`, packages `/Applications/AgentNudge.app`, and ad-hoc signs it with identifier `com.tanishkyadav.agent-nudge`.

## Permissions

On first use, grant:
1. **Accessibility** (`System Settings -> Privacy & Security -> Accessibility`) — required to send keystrokes (`CGEvent`). Click **Enable** in the popover banner if prompted.
2. **Automation (`Terminal`)** — macOS prompts once when AgentNudge queries or activates `Terminal.app` tabs.
