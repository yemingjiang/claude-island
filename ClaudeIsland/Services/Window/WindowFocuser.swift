//
//  WindowFocuser.swift
//  ClaudeIsland
//
//  Focuses windows using yabai
//

import AppKit
import Foundation

/// Focuses windows using yabai
actor WindowFocuser {
    static let shared = WindowFocuser()

    private init() {}

    /// Focus a window by ID
    func focusWindow(id: Int) async -> Bool {
        guard let yabaiPath = await WindowFinder.shared.getYabaiPath() else { return false }

        do {
            _ = try await ProcessExecutor.shared.run(yabaiPath, arguments: [
                "-m", "window", "--focus", String(id)
            ])
            return true
        } catch {
            return false
        }
    }

    /// Focus a yabai window, falling back to activating the owning app when yabai cannot focus it directly.
    func focusWindow(_ window: YabaiWindow) async -> Bool {
        if await focusWindow(id: window.id) {
            return true
        }

        return await activateApplication(pid: window.pid)
    }

    /// Focus the tmux window for a terminal
    func focusTmuxWindow(terminalPid: Int, windows: [YabaiWindow]) async -> Bool {
        // Try to find actual tmux window
        if let tmuxWindow = WindowFinder.shared.findTmuxWindow(forTerminalPid: terminalPid, windows: windows) {
            return await focusWindow(tmuxWindow)
        }

        // Fall back to any non-Claude window
        if let window = WindowFinder.shared.findNonClaudeWindow(forTerminalPid: terminalPid, windows: windows) {
            return await focusWindow(window)
        }

        return false
    }

    /// Focus the most relevant terminal window for a Claude session.
    func focusTerminalWindow(terminalPid: Int, titleHints: [String], windows: [YabaiWindow]) async -> Bool {
        guard let window = WindowFinder.shared.findPreferredWindow(
            forTerminalPid: terminalPid,
            titleHints: titleHints,
            windows: windows
        ) else {
            return false
        }

        return await focusWindow(window)
    }

    /// Focus the best matching terminal window across all terminal apps.
    func focusTerminalWindow(titleHints: [String], windows: [YabaiWindow]) async -> Bool {
        guard let window = WindowFinder.shared.findPreferredTerminalWindow(
            titleHints: titleHints,
            windows: windows
        ) else {
            return false
        }

        return await focusWindow(window)
    }

    private func activateApplication(pid: Int) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
            return false
        }

        if app.isHidden {
            app.unhide()
        }

        if app.activate(options: [.activateAllWindows]) {
            return true
        }

        if let bundleId = app.bundleIdentifier {
            let script = "tell application id \"\(bundleId)\" to activate"
            if case .success = await ProcessExecutor.shared.runWithResult("/usr/bin/osascript", arguments: ["-e", script]) {
                return true
            }
        }

        if let bundleURL = app.bundleURL {
            if case .success = await ProcessExecutor.shared.runWithResult("/usr/bin/open", arguments: ["-a", bundleURL.path]) {
                return true
            }
        }

        return false
    }
}
