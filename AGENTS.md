# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Build & Run

```bash
# Release build
./build_and_deploy.sh
# or: xcodebuild -scheme ClaudeIsland -configuration Release build

# Debug build
xcodebuild -scheme ClaudeIsland -configuration Debug build
```

No test targets exist in this project. Default verification after code changes is `./build_and_deploy.sh`.
Do not default to a separate `Debug build` first unless the user explicitly asks for it or release deploy is blocked for a specific reason.

## Project Skills

- For automated notch/menu regression checks, use the local skill at `.codex/skills/claude-island-menu-automation/`.
- The bundled skill should be kept aligned with the current menu bar status-item entrypoint, not the old notch-only flow.
- For deterministic local automation, prefer the app's distributed-notification automation hook to open the panel or switch to settings before doing AX-based button checks.
- Contributor notes and recent debugging lessons live in `docs/development-notes.md`.

## Project Overview

Codex Island is a macOS menu bar app (SwiftUI + AppKit) for Claude Code sessions. The primary entry point is a menu bar status item that opens a custom SwiftUI panel under the menu bar icon. It monitors sessions in real time, shows tool execution status, and lets users approve or deny tool permissions without switching to the terminal.

- **Platform:** macOS 15.6+ (Sequoia), Swift 5.0
- **UI:** SwiftUI views hosted in AppKit NSPanel (menu bar app, LSUIElement=true)
- **SPM Dependencies:** swift-markdown, Sparkle (auto-updates), mixpanel-swift (analytics)
- **App Sandbox:** Disabled (required for Unix sockets and process monitoring)

## Architecture

### Event Flow

```
Codex CLI → hook script (~/.Codex/hooks/) → Unix socket (/tmp/Codex-island.sock)
    → HookSocketServer → SessionStore.process(event) → sessionsPublisher (Combine)
    → ClaudeSessionMonitor (@MainActor) → SwiftUI views
```

### Key Modules

- **`SessionStore` (actor)** — Single source of truth. Thread-safe state mutations. All events funnel through `process()`, then publish via Combine.
- **`HookSocketServer`** — Unix domain socket server (GCD). Receives JSON events from Codex hooks. Supports **bidirectional** communication for permission responses (blocks socket until user responds).
- **`ClaudeSessionMonitor` (@MainActor)** — UI-friendly wrapper around SessionStore. Holds `@Published` properties for SwiftUI. Handles permission approvals/denials.
- **`NotchViewModel`** — Dynamic Island state machine (closed/opened/popping). Manages hover, animations, content switching.
- **`ConversationParser`** — Parses Codex JSONL conversation files for chat history.
- **`HookInstaller`** — Auto-installs the Python hook script into `~/.Codex/hooks/`.

### State Machine

`SessionPhase` enum: `idle → processing → waitingForInput | waitingForApproval(PermissionContext) → compacting → ended`. Transitions validated via `canTransition(to:)`.

### UI Structure

- **MenuBarController**: Owns the `NSStatusItem`, panel positioning, open/close lifecycle, and status-icon updates.
- **MenuBarPanel**: Borderless `NSPanel` used instead of `NSPopover` so the UI can stay visually pure black without the system bubble shell.
- **MenuBarPopoverView**: Main SwiftUI content for the opened panel. Content types: session list, settings menu, chat history.
- The legacy notch-specific files still exist in the repo, but the current user-facing entrypoint is the menu bar icon.

### External Integrations

- **Codex**: hooks, JSONL files, Unix socket
- **Tmux**: send messages, focus sessions
- **Sparkle**: auto-updates
- **Mixpanel**: anonymous analytics (app launch, session start only)
