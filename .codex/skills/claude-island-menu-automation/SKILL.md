---
name: claude-island-menu-automation
description: Use when validating Claude Island notch/menu interactions in this repository, especially automated clicks on the top-right menu button and menu actions like Quit. Covers build/deploy prerequisites, AX-based button discovery, and process-level verification that the app actually exits instead of just rebuilding the window.
---

# Claude Island Menu Automation

Use this skill for repeatable UI checks against the deployed app at `/Applications/Claude Island.app`.

This skill is specifically for this repository's notch panel geometry and menu structure. Keep it in sync with:

- `ClaudeIsland/Core/NotchViewModel.swift`
- `ClaudeIsland/Core/NotchGeometry.swift`
- `ClaudeIsland/UI/Views/NotchView.swift`

## When to use

- The user asks to verify the top-right config/menu button.
- The user asks to click menu items such as `Quit`.
- The app appears to shrink, rebuild, or refuse to exit after menu interaction.
- You need a reproducible regression check after changing notch/menu geometry.

## Workflow

1. Deploy the latest app if code changed.

```bash
./build_and_deploy.sh
```

2. Run the menu automation script.

```bash
.codex/skills/claude-island-menu-automation/scripts/menu_test.swift --action quit --launch --json
```

3. Treat process state as the source of truth.

- `AXPress` may return an error if the element disappears during app exit.
- A `Quit` test passes only if the app process disappears and stays gone for the full observation window.

## Key testing lessons

- Do not assume the menu is closed. Probe for `Quit` first.
- Do not hard-code the top-right button label. In practice it may surface as `Drag` or `Close`.
- Do not trust screen coordinates alone. Always confirm the element at a point belongs to the target app pid.
- A visible row is not enough. If `Quit` cannot be found in AX, the panel hit-test geometry is probably smaller than the rendered menu.
- For this app, regressions often come from opened-panel width/height mismatches rather than the `Quit` action itself.

## Script behavior

The bundled script:

- optionally launches `/Applications/Claude Island.app`
- clicks the notch center to bring the panel into an interactive state
- discovers the top-right menu button via AX ownership
- discovers the `Quit` button via AX description scanning
- presses the target control
- verifies exit by polling for the app process for 8 seconds by default

## Debugging

List visible buttons and their coordinates:

```bash
.codex/skills/claude-island-menu-automation/scripts/menu_test.swift --action buttons --launch
```

Extend the exit observation window:

```bash
.codex/skills/claude-island-menu-automation/scripts/menu_test.swift --action quit --launch --timeout 12
```

If the script cannot find `Quit`:

- check whether menu height/width constants changed
- check whether the panel is still anchored at the same top-edge geometry
- compare the current menu layout with `NotchViewModel.openedSize` and `NotchGeometry.openedScreenRect`
