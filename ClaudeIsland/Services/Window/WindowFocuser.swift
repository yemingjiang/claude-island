//
//  WindowFocuser.swift
//  ClaudeIsland
//
//  Focuses terminal apps and selects the best matching Ghostty tab.
//

import AppKit
import Foundation
import os.log

actor WindowFocuser {
    static let shared = WindowFocuser()
    private static let logger = Logger(subsystem: "com.claudeisland", category: "WindowFocuser")

    private init() {}

    func focusTerminalApplication(
        pid: Int,
        workingDirectory: String? = nil,
        titleHints: [String] = [],
        ghosttyWindowId: String? = nil,
        ghosttyTabId: String? = nil
    ) async -> Bool {
        guard await activateApplication(pid: pid) else {
            Self.logger.warning("Failed to activate terminal app for pid \(pid, privacy: .public)")
            return false
        }

        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)),
              app.bundleIdentifier == "com.mitchellh.ghostty" else {
            return true
        }

        if let ghosttyWindowId, let ghosttyTabId,
           await selectGhosttyTabById(windowId: ghosttyWindowId, tabId: ghosttyTabId) {
            return true
        }

        return await selectMatchingGhosttyTabIfNeeded(
            workingDirectory: workingDirectory,
            titleHints: titleHints
        )
    }

    func focusPreferredTerminalApplication(
        workingDirectory: String? = nil,
        titleHints: [String] = [],
        ghosttyWindowId: String? = nil,
        ghosttyTabId: String? = nil
    ) async -> Bool {
        guard let app = await preferredRunningTerminalApplication() else {
            Self.logger.warning("No running terminal application found")
            return false
        }

        return await focusTerminalApplication(
            pid: Int(app.processIdentifier),
            workingDirectory: workingDirectory,
            titleHints: titleHints,
            ghosttyWindowId: ghosttyWindowId,
            ghosttyTabId: ghosttyTabId
        )
    }

    private func preferredRunningTerminalApplication() async -> NSRunningApplication? {
        await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { app in
                    if let bundleId = app.bundleIdentifier,
                       TerminalAppRegistry.isTerminalBundle(bundleId) {
                        return true
                    }

                    return TerminalAppRegistry.isTerminal(app.localizedName ?? "")
                }
                .sorted { lhs, rhs in
                    terminalPriority(lhs) < terminalPriority(rhs)
                }
                .first
        }
    }

    private nonisolated func terminalPriority(_ app: NSRunningApplication) -> Int {
        switch app.bundleIdentifier {
        case "com.mitchellh.ghostty":
            return 0
        case "com.googlecode.iterm2":
            return 1
        case "com.apple.Terminal":
            return 2
        default:
            return 10
        }
    }

    private func activateApplication(pid: Int) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
            Self.logger.warning("No running app found for pid \(pid, privacy: .public)")
            return false
        }

        let activated = await MainActor.run { () -> Bool in
            if app.isHidden {
                app.unhide()
            }
            return app.activate(options: [.activateAllWindows])
        }
        if activated {
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

    private func selectMatchingGhosttyTabIfNeeded(
        workingDirectory: String?,
        titleHints: [String]
    ) async -> Bool {
        let normalizedWorkingDirectory = workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let normalizedHints = titleHints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedWorkingDirectory.isEmpty || !normalizedHints.isEmpty else {
            return false
        }

        let scriptLines = [
            "on run argv",
            "tell application id \"com.mitchellh.ghostty\"",
            "set targetCwd to item 1 of argv as text",
            "set matchedWindow to missing value",
            "set matchedTab to missing value",
            "set bestScore to -1",
            "repeat with currentWindow in windows",
            "repeat with currentTab in tabs of currentWindow",
            "set tabName to name of currentTab as text",
            "repeat with currentTerminal in terminals of currentTab",
            "set terminalCwd to working directory of currentTerminal as text",
            "set currentScore to 0",
            "if targetCwd is not \"\" then",
            "if terminalCwd is equal to targetCwd then",
            "set currentScore to currentScore + 1000",
            "else if terminalCwd starts with (targetCwd & \"/\") then",
            "set currentScore to currentScore + 800",
            "else if targetCwd starts with (terminalCwd & \"/\") then",
            "set currentScore to currentScore + 600",
            "end if",
            "end if",
            "ignoring case",
            "if tabName contains \"claude code\" then",
            "set currentScore to currentScore + 250",
            "else if tabName contains \"claude\" then",
            "set currentScore to currentScore + 180",
            "end if",
            "if (count of argv) > 1 then",
            "repeat with hintIndex from 2 to (count of argv)",
            "set currentHint to item hintIndex of argv as text",
            "if currentHint is not \"\" then",
            "if tabName is equal to currentHint then",
            "set currentScore to currentScore + 140",
            "else if tabName contains currentHint then",
            "set currentScore to currentScore + 90",
            "else if terminalCwd is equal to currentHint then",
            "set currentScore to currentScore + 120",
            "else if terminalCwd contains currentHint then",
            "set currentScore to currentScore + 40",
            "end if",
            "end if",
            "end repeat",
            "end if",
            "end ignoring",
            "if currentScore > bestScore then",
            "set bestScore to currentScore",
            "set matchedWindow to currentWindow",
            "set matchedTab to currentTab",
            "end if",
            "end repeat",
            "end repeat",
            "end repeat",
            "activate",
            "if matchedTab is not missing value then",
            "activate window matchedWindow",
            "select tab matchedTab",
            "delay 0.05",
            "if (name of selected tab of matchedWindow as text) is equal to (name of matchedTab as text) then",
            "return \"matched\"",
            "end if",
            "return \"mismatch\"",
            "end if",
            "end tell",
            "return \"nomatch\"",
            "end run"
        ]

        var arguments = scriptLines.flatMap { ["-e", $0] }
        arguments.append("--")
        arguments.append(normalizedWorkingDirectory)
        arguments.append(contentsOf: normalizedHints)

        let result = await ProcessExecutor.shared.runWithResult("/usr/bin/osascript", arguments: arguments)
        switch result {
        case .success(let processResult):
            let output = processResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if output == "matched" {
                return true
            }
            if output != "matched" {
                Self.logger.info("Ghostty tab match not found for cwd \(normalizedWorkingDirectory, privacy: .public) and hints: \(normalizedHints.joined(separator: ", "), privacy: .public)")
            }
            return false
        case .failure(let error):
            Self.logger.error("Ghostty tab selection failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func selectGhosttyTabById(windowId: String, tabId: String) async -> Bool {
        let scriptLines = [
            "on run argv",
            "tell application id \"com.mitchellh.ghostty\"",
            "set targetWindowId to item 1 of argv as text",
            "set targetTabId to item 2 of argv as text",
            "repeat with currentWindow in windows",
            "if (id of currentWindow as text) is equal to targetWindowId then",
            "repeat with currentTab in tabs of currentWindow",
            "if (id of currentTab as text) is equal to targetTabId then",
            "activate",
            "activate window currentWindow",
            "select tab currentTab",
            "delay 0.05",
            "if (id of selected tab of currentWindow as text) is equal to targetTabId then",
            "return \"matched\"",
            "end if",
            "return \"mismatch\"",
            "end if",
            "end repeat",
            "return \"missing-tab\"",
            "end if",
            "end repeat",
            "end tell",
            "return \"missing-window\"",
            "end run"
        ]

        let arguments = scriptLines.flatMap { ["-e", $0] } + ["--", windowId, tabId]
        let result = await ProcessExecutor.shared.runWithResult("/usr/bin/osascript", arguments: arguments)
        switch result {
        case .success(let processResult):
            let output = processResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if output == "matched" {
                return true
            }
            Self.logger.info("Ghostty exact tab match failed for window \(windowId, privacy: .public) tab \(tabId, privacy: .public): \(output, privacy: .public)")
            return false
        case .failure(let error):
            Self.logger.error("Ghostty exact tab selection failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
