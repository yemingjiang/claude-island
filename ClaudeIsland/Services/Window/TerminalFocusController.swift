//
//  TerminalFocusController.swift
//  ClaudeIsland
//
//  Focuses the terminal app that hosts a Claude session and, when possible,
//  selects the best matching tmux pane or Ghostty tab.
//

import AppKit
import Foundation

actor TerminalFocusController {
    static let shared = TerminalFocusController()

    private init() {}

    func focusWindow(forClaudePid claudePid: Int) async -> Bool {
        await focusWindow(
            forClaudePid: claudePid,
            workingDirectory: nil,
            windowHint: nil,
            isInTmux: nil,
            tty: nil,
            ghosttyWindowId: nil,
            ghosttyTabId: nil
        )
    }

    func focusWindow(
        forClaudePid claudePid: Int,
        workingDirectory: String?,
        windowHint: String?,
        isInTmux: Bool?,
        tty: String?,
        ghosttyWindowId: String?,
        ghosttyTabId: String?
    ) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        let resolvedIsInTmux = isInTmux ?? ProcessTreeBuilder.shared.isInTmux(pid: claudePid, tree: tree)

        if resolvedIsInTmux {
            return await focusTmuxInstance(
                claudePid: claudePid,
                workingDirectory: workingDirectory,
                windowHint: windowHint,
                tty: tty,
                ghosttyWindowId: ghosttyWindowId,
                ghosttyTabId: ghosttyTabId,
                tree: tree
            )
        }

        if let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: claudePid, tree: tree) {
            return await WindowFocuser.shared.focusTerminalApplication(
                pid: terminalPid,
                workingDirectory: workingDirectory,
                titleHints: titleHints(workingDirectory: workingDirectory, windowHint: windowHint),
                tty: tty,
                ghosttyWindowId: ghosttyWindowId,
                ghosttyTabId: ghosttyTabId
            )
        }

        if let workingDirectory {
            return await focusWindow(
                forWorkingDir: workingDirectory,
                windowHint: windowHint,
                tty: tty,
                ghosttyWindowId: ghosttyWindowId,
                ghosttyTabId: ghosttyTabId
            )
        }

        return false
    }

    func focusWindow(forWorkingDirectory workingDirectory: String) async -> Bool {
        await focusWindow(forWorkingDirectory: workingDirectory, windowHint: nil, tty: nil, ghosttyWindowId: nil, ghosttyTabId: nil)
    }

    func focusWindow(forWorkingDirectory workingDirectory: String, windowHint: String?) async -> Bool {
        await focusWindow(forWorkingDirectory: workingDirectory, windowHint: windowHint, tty: nil, ghosttyWindowId: nil, ghosttyTabId: nil)
    }

    func focusWindow(
        forWorkingDirectory workingDirectory: String,
        windowHint: String?,
        tty: String?,
        ghosttyWindowId: String?,
        ghosttyTabId: String?
    ) async -> Bool {
        await focusWindow(
            forWorkingDir: workingDirectory,
            windowHint: windowHint,
            tty: tty,
            ghosttyWindowId: ghosttyWindowId,
            ghosttyTabId: ghosttyTabId
        )
    }

    private func focusTmuxInstance(
        claudePid: Int,
        workingDirectory: String?,
        windowHint: String?,
        tty: String?,
        ghosttyWindowId: String?,
        ghosttyTabId: String?,
        tree: [Int: ProcessInfo]
    ) async -> Bool {
        guard let target = await TmuxController.shared.findTmuxTarget(forClaudePid: claudePid) else {
            return false
        }

        _ = await TmuxController.shared.switchToPane(target: target)

        if let terminalPid = await findTmuxClientTerminal(forSession: target.session, tree: tree) {
            let fallbackWorkingDirectory = workingDirectory ?? ProcessTreeBuilder.shared.getWorkingDirectory(forPid: claudePid)
            return await WindowFocuser.shared.focusTerminalApplication(
                pid: terminalPid,
                workingDirectory: fallbackWorkingDirectory,
                titleHints: titleHints(workingDirectory: fallbackWorkingDirectory, windowHint: windowHint),
                tty: tty,
                ghosttyWindowId: ghosttyWindowId,
                ghosttyTabId: ghosttyTabId
            )
        }

        return false
    }

    private func focusWindow(
        forWorkingDir workingDir: String,
        windowHint: String?,
        tty: String?,
        ghosttyWindowId: String?,
        ghosttyTabId: String?
    ) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()

        let focusedTmuxPane = await focusTmuxPane(
            forWorkingDir: workingDir,
            windowHint: windowHint,
            tree: tree
        )
        if focusedTmuxPane {
            return true
        }

        return await WindowFocuser.shared.focusPreferredTerminalApplication(
            workingDirectory: workingDir,
            titleHints: titleHints(workingDirectory: workingDir, windowHint: windowHint),
            tty: tty,
            ghosttyWindowId: ghosttyWindowId,
            ghosttyTabId: ghosttyTabId
        )
    }

    private func findTmuxClientTerminal(forSession session: String, tree: [Int: ProcessInfo]) async -> Int? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return nil }

        do {
            let output = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "list-clients", "-t", session, "-F", "#{client_pid}"
            ])

            let clientPids = output.components(separatedBy: "\n")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

            for clientPid in clientPids {
                var currentPid = clientPid
                while currentPid > 1 {
                    guard let info = tree[currentPid] else { break }
                    if isTerminalProcess(info.command),
                       NSRunningApplication(processIdentifier: pid_t(currentPid)) != nil {
                        return currentPid
                    }
                    currentPid = info.ppid
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    private nonisolated func isTerminalProcess(_ command: String) -> Bool {
        TerminalAppRegistry.isTerminal(command) || command.lowercased().contains("ghostty")
    }

    private func focusTmuxPane(
        forWorkingDir workingDir: String,
        windowHint: String?,
        tree: [Int: ProcessInfo]
    ) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return false }

        do {
            let panesOutput = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}"
            ])

            let panes = panesOutput.components(separatedBy: "\n").filter { !$0.isEmpty }

            for pane in panes {
                let parts = pane.components(separatedBy: "|")
                guard parts.count >= 2,
                      let panePid = Int(parts[1]) else { continue }

                let targetString = parts[0]

                for (pid, info) in tree {
                    let isChild = ProcessTreeBuilder.shared.isDescendant(targetPid: pid, ofAncestor: panePid, tree: tree)
                    let isClaude = info.command.lowercased().contains("claude")
                    guard isChild, isClaude else { continue }

                    guard let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: pid),
                          cwd == workingDir else { continue }

                    if let target = TmuxTarget(from: targetString) {
                        _ = await TmuxController.shared.switchToPane(target: target)

                        if let terminalPid = await findTmuxClientTerminal(forSession: target.session, tree: tree) {
                            return await WindowFocuser.shared.focusTerminalApplication(
                                pid: terminalPid,
                                workingDirectory: workingDir,
                                titleHints: titleHints(workingDirectory: workingDir, windowHint: windowHint),
                                tty: nil,
                                ghosttyWindowId: nil,
                                ghosttyTabId: nil
                            )
                        }
                    }
                    return true
                }
            }
        } catch {
            return false
        }

        return false
    }

    private nonisolated func titleHints(workingDirectory: String?, windowHint: String?) -> [String] {
        var hints: [String] = []

        if let windowHint, !windowHint.isEmpty {
            hints.append(windowHint)
        }

        if let workingDirectory, !workingDirectory.isEmpty {
            let url = URL(fileURLWithPath: workingDirectory)
            hints.append(url.lastPathComponent)
            hints.append(workingDirectory)
        }

        return hints
    }
}
