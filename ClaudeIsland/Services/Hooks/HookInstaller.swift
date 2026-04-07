//
//  HookInstaller.swift
//  ClaudeIsland
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation

struct HookInstaller {

    /// Install hook script and update settings.json on app launch
    static func installIfNeeded() {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true
        )

        if let bundled = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") {
            updateScriptIfNeeded(from: bundled, to: pythonScript)
        }

        updateSettings(at: settings)
    }

    private static func updateSettings(at settingsURL: URL) {
        let existingData = try? Data(contentsOf: settingsURL)
        var json: [String: Any] = [:]
        if let data = existingData,
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let command = "\(python) ~/.claude/hooks/claude-island-state.py"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }

            entries.removeAll { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { hook in
                    let cmd = hook["command"] as? String ?? ""
                    return cmd.contains("claude-island-state.py")
                }
            }

            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
        ]

        for (event, config) in hookEvents {
            if var existingEvent = hooks[event] as? [[String: Any]] {
                existingEvent.append(contentsOf: config)
                hooks[event] = existingEvent
            } else {
                hooks[event] = config
            }
        }

        json["hooks"] = hooks

        guard let data = canonicalJSONData(from: json) else { return }
        if existingData == data {
            return
        }

        try? data.write(to: settingsURL)
    }

    /// Check if hooks are currently installed
    static func isInstalled() -> Bool {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let settings = claudeDir.appendingPathComponent("settings.json")

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("claude-island-state.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? FileManager.default.removeItem(at: pythonScript)

        guard let existingData = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains("claude-island-state.py")
                        }
                    }
                    return false
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        guard let data = canonicalJSONData(from: json), data != existingData else { return }
        try? data.write(to: settings)
    }

    private static func updateScriptIfNeeded(from sourceURL: URL, to destinationURL: URL) {
        let sourceData = try? Data(contentsOf: sourceURL)
        let destinationData = try? Data(contentsOf: destinationURL)

        if sourceData != destinationData {
            try? FileManager.default.removeItem(at: destinationURL)
            try? FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }

        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destinationURL.path
        )
    }

    private static func canonicalJSONData(from object: [String: Any]) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }
}
