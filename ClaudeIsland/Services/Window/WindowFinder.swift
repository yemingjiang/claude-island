//
//  WindowFinder.swift
//  ClaudeIsland
//
//  Finds windows using yabai window manager
//

import AppKit
import Foundation

/// Information about a yabai window
struct YabaiWindow: Sendable {
    let id: Int
    let pid: Int
    let app: String
    let title: String
    let space: Int
    let isVisible: Bool
    let hasFocus: Bool

    nonisolated init?(from dict: [String: Any]) {
        guard let id = dict["id"] as? Int,
              let pid = dict["pid"] as? Int else { return nil }

        self.id = id
        self.pid = pid
        self.app = dict["app"] as? String ?? ""
        self.title = dict["title"] as? String ?? ""
        self.space = dict["space"] as? Int ?? 0
        self.isVisible = dict["is-visible"] as? Bool ?? false
        self.hasFocus = dict["has-focus"] as? Bool ?? false
    }
}

/// Finds windows using yabai
actor WindowFinder {
    static let shared = WindowFinder()

    private var yabaiPath: String?
    private var isAvailableCache: Bool?

    private init() {}

    /// Check if yabai is available (caches result)
    func isYabaiAvailable() -> Bool {
        if let cached = isAvailableCache { return cached }

        let paths = ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                yabaiPath = path
                isAvailableCache = true
                return true
            }
        }
        isAvailableCache = false
        return false
    }

    /// Get the yabai path if available
    func getYabaiPath() -> String? {
        _ = isYabaiAvailable()
        return yabaiPath
    }

    /// Get all windows from yabai
    func getAllWindows() async -> [YabaiWindow] {
        guard isYabaiAvailable(), let path = yabaiPath else { return [] }

        do {
            let output = try await ProcessExecutor.shared.run(path, arguments: ["-m", "query", "--windows"])
            guard let data = output.data(using: .utf8),
                  let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            return jsonArray.compactMap { YabaiWindow(from: $0) }
        } catch {
            return []
        }
    }

    /// Get the current space number
    nonisolated func getCurrentSpace(windows: [YabaiWindow]) -> Int? {
        windows.first(where: { $0.hasFocus })?.space
    }

    /// Find windows for a terminal PID
    nonisolated func findWindows(forTerminalPid pid: Int, windows: [YabaiWindow]) -> [YabaiWindow] {
        windows.filter { $0.pid == pid }
    }

    /// Find tmux window (title contains "tmux")
    nonisolated func findTmuxWindow(forTerminalPid pid: Int, windows: [YabaiWindow]) -> YabaiWindow? {
        windows.first { $0.pid == pid && $0.title.lowercased().contains("tmux") }
    }

    /// Find any non-Claude window for a terminal
    nonisolated func findNonClaudeWindow(forTerminalPid pid: Int, windows: [YabaiWindow]) -> YabaiWindow? {
        windows.first { $0.pid == pid && !$0.title.contains("✳") }
    }

    /// Find the best matching window for a terminal app.
    /// Prefers title matches for the current Claude session, then any visible window, then any non-Claude window.
    nonisolated func findPreferredWindow(forTerminalPid pid: Int, titleHints: [String], windows: [YabaiWindow]) -> YabaiWindow? {
        let candidates = windows.filter { $0.pid == pid }
        guard !candidates.isEmpty else { return nil }

        let normalizedHints = titleHints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 2 }

        if let titleMatch = candidates.first(where: { window in
            let title = window.title.lowercased()
            return normalizedHints.contains(where: { title.contains($0) })
        }) {
            return titleMatch
        }

        if let visible = candidates.first(where: { $0.isVisible && !$0.title.contains("✳") }) {
            return visible
        }

        if let nonClaude = findNonClaudeWindow(forTerminalPid: pid, windows: candidates) {
            return nonClaude
        }

        return candidates.first
    }

    /// Find the best matching terminal window across all terminal apps.
    nonisolated func findPreferredTerminalWindow(titleHints: [String], windows: [YabaiWindow]) -> YabaiWindow? {
        let candidates = windows.filter { isTerminalWindow($0) }
        guard !candidates.isEmpty else { return nil }

        let normalizedHints = titleHints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 2 }

        if let titleMatch = candidates.first(where: { window in
            let title = window.title.lowercased()
            return normalizedHints.contains(where: { title.contains($0) })
        }) {
            return titleMatch
        }

        if let focused = candidates.first(where: \.hasFocus) {
            return focused
        }

        if let visible = candidates.first(where: \.isVisible) {
            return visible
        }

        return candidates.first
    }

    private nonisolated func isTerminalWindow(_ window: YabaiWindow) -> Bool {
        if TerminalAppRegistry.isTerminal(window.app) {
            return true
        }

        guard let app = NSRunningApplication(processIdentifier: pid_t(window.pid)) else {
            return false
        }

        if let bundleId = app.bundleIdentifier, TerminalAppRegistry.isTerminalBundle(bundleId) {
            return true
        }

        return TerminalAppRegistry.isTerminal(app.localizedName ?? "")
    }
}
