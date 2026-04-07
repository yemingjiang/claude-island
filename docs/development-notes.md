# Development Notes

This document captures the main implementation lessons from the recent menu bar migration and session-tracking fixes.

## Current UI Architecture

- The app no longer uses the old notch overlay as its primary entry point.
- The entry point is a macOS menu bar status item in the top-right menu bar.
- Clicking the status item opens a custom borderless `NSPanel` that hosts SwiftUI content.
- The custom panel is intentional. `NSPopover` added a gray system bubble shell and arrow that conflicted with the app's all-black visual design.

Relevant files:

- `ClaudeIsland/App/MenuBarController.swift`
- `ClaudeIsland/UI/Views/MenuBarPopoverView.swift`

## Why `NSPopover` Was Replaced

- `NSPopover` always renders a system container around the content.
- Even when the SwiftUI content is pure black, the popover still shows a gray outer plate and arrow.
- That shell also made left/right spacing harder to judge because the visible background was wider than the actual content view.
- A custom `NSPanel` gave full control over background, shadow, close behavior, and anchoring under the menu bar item.

## Menu Automation Lessons

- The menu bar status item is not a stable automation surface by itself.
- Depending on macOS internals, the status item may not appear as a discoverable app-owned AX button.
- For project-local automation, the reliable approach is:
  1. ask the running app to open the panel or switch to the settings menu through a local automation notification
  2. once the panel is open, use AX hit-testing inside the panel to locate concrete controls such as `Quit`
  3. verify the final process-level outcome

Relevant files:

- `ClaudeIsland/App/AppDelegate.swift`
- `ClaudeIsland/App/MenuBarController.swift`
- `.codex/skills/claude-island-menu-automation/scripts/menu_test.swift`

## Session Tracking Lessons

### 1. Invalid hook events must be filtered in more than one place

Some external SDK or queued runs can emit hook-like events before a real Claude session exists.

Symptoms:

- fake sessions with `pid == 1`
- missing or bogus JSONL files under `~/.claude/projects/...`
- phantom rows in "Active Sessions"

Filtering now exists in three layers:

- `ClaudeIsland/Resources/claude-island-state.py`
- `ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift`
- `ClaudeIsland/Services/State/SessionStore.swift`

Do not rely on only one layer. `ClaudeSessionMonitor` can start interrupt watchers before `SessionStore` decides to ignore an event.

### 2. Stale sessions must be pruned proactively

Relying only on explicit `ended` events is not enough.

Observed failure mode:

- only one real `claude` process is alive
- UI still shows multiple active sessions
- old sessions remain in memory because they never emitted a clean `ended`

Current pruning strategy in `SessionStore.publishState()`:

- keep sessions whose PID is still alive and still maps to a `claude` process
- otherwise keep sessions whose TTY still matches a live `claude` process
- otherwise give a short grace period, then drop them
- deduplicate sessions that map to the same runtime identity and keep the newest one

Runtime identity priority:

1. `pid`
2. `tty + cwd`
3. `ghostty window/tab`

### 3. JSONL existence is a strong sanity check

If a hook event has:

- no valid PID
- no TTY
- no Ghostty context
- and no backing JSONL file

it is almost certainly not a real live Claude session and should be ignored.

## Quit / Lifecycle Lessons

- `Quit` must be verified at the process level, not just visually.
- A menu item can appear to close the panel while the app process keeps running.
- The app needs an explicit shutdown path that stops socket servers, watchers, timers, and windows.

Relevant files:

- `ClaudeIsland/App/AppDelegate.swift`
- `ClaudeIsland/Events/EventMonitors.swift`

## Build / Deploy Lessons

### 1. Test the installed app, not only DerivedData

The real product behavior is what happens from `/Applications/Claude Island.app`.

Why:

- login items point at `/Applications`
- permissions are granted to the installed bundle
- signing issues may appear only after copy/deploy

### 2. Keep only one runnable copy

Multiple copies with the same bundle identifier cause confusing behavior:

- permissions appear granted but runtime checks still fail
- quitting one copy can look like another one relaunched it

The app now guards against launching from non-`/Applications` paths unless explicitly overridden for development.

### 3. Verify the installed app signature

The deployment script should not assume the copied app is still valid just because the build artifact was signed.

Current deployment flow:

1. build
2. normalize the build artifact signature
3. copy to `/Applications`
4. verify the installed app signature
5. only re-sign the installed app if verification fails

Relevant file:

- `build_and_deploy.sh`

## Accessibility UI Lessons

- "Accessibility enabled" UI must not depend on a stale captured bool from initial view construction.
- A single source of truth is better than ad-hoc local view state.
- Startup-time checks are enough for the current product requirement; continuous polling is unnecessary.

Relevant files:

- `ClaudeIsland/App/AccessibilityPermissionStore.swift`
- `ClaudeIsland/UI/Views/NotchMenuView.swift`

## Recommended Verification Flow

When changing menu UI, quit flow, or session tracking:

1. Run `./build_and_deploy.sh`
2. Test `/Applications/Claude Island.app`
3. Verify `Quit` by checking that the process exits and stays gone
4. Compare UI session count with `ps` output for real `claude` processes
5. If session count is wrong, inspect:
   - fake hook events
   - missing JSONL files
   - stale in-memory sessions that never got `ended`
