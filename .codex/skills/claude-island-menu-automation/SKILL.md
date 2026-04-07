---
name: claude-island-menu-automation
description: Use when validating Claude Island menu bar interactions in this repository, especially the top-right status-item entrypoint, opened panel behavior, and menu actions like Quit. Covers build/deploy prerequisites, AX-based validation, and process-level verification that the app actually exits instead of only hiding its panel.
---

# Claude Island Menu Automation

Use this skill for repeatable UI checks against the deployed app at `/Applications/Claude Island.app`.

This skill is specifically for this repository's current menu bar status-item and custom panel flow. Keep it in sync with:

- `ClaudeIsland/App/MenuBarController.swift`
- `ClaudeIsland/App/AppDelegate.swift`
- `ClaudeIsland/UI/Views/MenuBarPopoverView.swift`
- `ClaudeIsland/Core/NotchViewModel.swift`

## When to use

- The user asks to verify the top-right menu bar icon or the opened panel.
- The user asks to click menu items such as `Quit`.
- The app appears to shrink, rebuild, or refuse to exit after menu interaction.
- You need a reproducible regression check after changing menu bar panel geometry or session-list behavior.

## Workflow

1. Deploy the latest app if code changed.

```bash
./build_and_deploy.sh
```

2. Run the menu automation script or equivalent AX validation helper.

```bash
.codex/skills/claude-island-menu-automation/scripts/menu_test.swift --action quit --launch --json
```

3. Prefer the app's built-in automation entrypoints over brittle direct menu bar clicking.

- The script first posts a distributed notification to ask the running app to open the panel or switch to settings.
- Only after the panel is open does it use AX hit-testing to find concrete buttons such as `Quit`.
- This is intentional because the menu bar status item is not always discoverable as a stable AX node.

4. Treat process state as the source of truth.

- A `Quit` test passes only if the app process disappears and stays gone for the full observation window.
- For this repository's current menu, the `Quit` verification path should prefer the app's automation hook over trying to scroll to the bottom row of the settings menu.

## Key testing lessons

- Do not assume the menu is closed. Probe for `Quit` first.
- Do not assume the old notch entrypoint still exists. The current app opens from a menu bar status item, but tests should prefer the app's local automation notification to reveal the panel.
- Do not trust raw screen coordinates alone. Always confirm the element at a point belongs to the target app pid.
- A visible row is not enough. If `Quit` cannot be found in AX, the panel hit-test geometry is probably smaller than the rendered menu.
- For this app, regressions often come from the panel host or session-state logic rather than the button action itself.
- Compare UI session count with real `claude` processes from `ps`. Session overcount usually means fake hook events or stale sessions that were not pruned.
- The custom `NSPanel` host is intentional. `NSPopover` adds a gray system bubble shell that changes the visible layout.
- The menu bar icon itself may not be exposed as a stable app-owned AX button. Use the automation notification path first and only fall back to icon discovery when debugging the entrypoint itself.
- The settings menu is scrollable. Do not make the bottom `Quit` row the only automation anchor.

## Script behavior

The bundled script is the current source of truth for menu automation in this repository.

Today the reliable checks are:

- deploy the app to `/Applications`
- post a local automation notification to open the panel or show the settings menu
- discover actionable controls through AX ownership inside the opened panel
- verify process-level outcomes such as real app exit
- cross-check session counts against live `claude` processes

## Debugging

Recommended checks:

```bash
ps -axo pid,ppid,tty,etime,command | rg ' claude($| )'
```

```bash
/usr/bin/log show --last 2m --predicate 'subsystem == "com.claudeisland"' --style compact | tail -n 80
```

Legacy script examples:

```bash
.codex/skills/claude-island-menu-automation/scripts/menu_test.swift --action quit --launch --timeout 12
```

If the script cannot find `Quit`:

- check whether the automation notification is still registered in `AppDelegate`
- check whether the opened panel is hosted by `MenuBarController` and not by a system popover
- compare the current layout with `MenuBarController`, `MenuBarPopoverView`, and `NotchViewModel.openedSize`
