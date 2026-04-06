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
- The bundled script covers the current top-right menu toggle and `Quit` verification path against `/Applications/Claude Island.app`.

## Project Overview

Codex Island is a macOS menu bar app (SwiftUI + AppKit) that displays Dynamic Island-style notifications for Codex CLI sessions. It monitors sessions in real-time, shows tool execution status in an animated notch overlay, and lets users approve/deny tool permissions directly from the notch without switching to the terminal.

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

- **NotchWindow** (NSPanel subclass): Transparent overlay on the notch, ignores mouse events by default. Global event monitors detect hover/click.
- **NotchView**: Main SwiftUI view. Header row always visible, content area expands on hover. Content types: session list, settings menu, chat history.
- Spring animations for expand/collapse, matched geometry effects for transitions.

### External Integrations

- **Codex**: hooks, JSONL files, Unix socket
- **Tmux**: send messages, focus sessions
- **Sparkle**: auto-updates
- **Mixpanel**: anonymous analytics (app launch, session start only)
