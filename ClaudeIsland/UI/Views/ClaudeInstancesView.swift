//
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            instancesList
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack(spacing: 10) {
            ClaudeCrabIcon(
                size: 18,
                color: Color(red: 0.95, green: 0.68, blue: 0.55)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("Waiting for Claude")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))

                Text("Run `claude` in Terminal to see live activity")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.42))
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        sessionMonitor.instances.sorted { a, b in
            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    private var notificationSessions: [SessionState] {
        sortedInstances.filter {
            $0.phase == SessionPhase.processing ||
            $0.phase == SessionPhase.compacting ||
            $0.phase.isWaitingForApproval ||
            $0.phase == SessionPhase.waitingForInput
        }
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }

    private var instancesList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                SessionOverviewBar(sessions: sortedInstances)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        title: "Notifications",
                        subtitle: "Sessions that are running, waiting, or need attention"
                    )

                    if notificationSessions.isEmpty {
                        EmptySectionCard(
                            icon: "bell.slash",
                            title: "No active notifications",
                            subtitle: "Claude sessions are tracked below while they stay alive."
                        )
                    } else {
                        VStack(spacing: 4) {
                            ForEach(notificationSessions) { session in
                                InstanceRow(
                                    session: session,
                                    onFocus: { focusSession(session) },
                                    onChat: { openChat(session) },
                                    onArchive: { archiveSession(session) },
                                    onApprove: { approveSession(session) },
                                    onReject: { rejectSession(session) }
                                )
                                .id("notification-\(session.stableId)")
                            }
                        }
                    }
                }

                Divider()
                    .overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        title: "Active Sessions",
                        subtitle: "Tracked Claude Code sessions on this Mac"
                    )

                    VStack(spacing: 8) {
                        ForEach(sortedInstances) { session in
                            ActiveSessionCard(
                                session: session,
                                onFocus: { focusSession(session) }
                            )
                            .id("active-\(session.stableId)")
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        Task {
            if let pid = session.pid {
                _ = await TerminalFocusController.shared.focusWindow(
                    forClaudePid: pid,
                    workingDirectory: session.cwd,
                    windowHint: session.windowHint,
                    isInTmux: session.isInTmux,
                    tty: session.tty,
                    ghosttyWindowId: session.ghosttyWindowId,
                    ghosttyTabId: session.ghosttyTabId
                )
            } else {
                _ = await TerminalFocusController.shared.focusWindow(
                    forWorkingDirectory: session.cwd,
                    windowHint: session.windowHint,
                    tty: session.tty,
                    ghosttyWindowId: session.ghosttyWindowId,
                    ghosttyTabId: session.ghosttyTabId
                )
            }
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.42))
        }
    }
}

private struct SessionOverviewBar: View {
    let sessions: [SessionState]

    private struct Metric: Identifiable {
        let id: String
        let label: String
        let value: String
        let tint: Color
    }

    private var processingCount: Int {
        sessions.filter { $0.phase == SessionPhase.processing || $0.phase == SessionPhase.compacting }.count
    }

    private var waitingCount: Int {
        sessions.filter { $0.phase == SessionPhase.waitingForInput || $0.phase.isWaitingForApproval }.count
    }

    private var tmuxCount: Int {
        sessions.filter(\.isInTmux).count
    }

    private var metrics: [Metric] {
        [
            Metric(id: "active", label: "Active", value: "\(sessions.count)", tint: .white),
            Metric(id: "running", label: "Running", value: "\(processingCount)", tint: Color(red: 0.85, green: 0.47, blue: 0.34)),
            Metric(id: "waiting", label: "Waiting", value: "\(waitingCount)", tint: TerminalColors.green),
            Metric(id: "tmux", label: "tmux", value: "\(tmuxCount)", tint: Color(red: 0.45, green: 0.72, blue: 0.95))
        ]
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(metrics) { metric in
                    SummaryPill(label: metric.label, value: metric.value, tint: metric.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SummaryPill(label: metrics[0].label, value: metrics[0].value, tint: metrics[0].tint)
                    SummaryPill(label: metrics[1].label, value: metrics[1].value, tint: metrics[1].tint)
                }
                HStack(spacing: 8) {
                    SummaryPill(label: metrics[2].label, value: metrics[2].value, tint: metrics[2].tint)
                    SummaryPill(label: metrics[3].label, value: metrics[3].value, tint: metrics[3].tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SummaryPill: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(tint.opacity(0.95))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
        )
    }
}

private struct EmptySectionCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.05))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.42))
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.04))
        )
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var isHovered = false
    @State private var spinnerPhase = 0

    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let spinnerTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    private var canFocusTerminal: Bool {
        session.pid != nil || !session.cwd.isEmpty
    }

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // State indicator on left
            stateIndicator
                .frame(width: 14)

            // Text content
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                // Show tool call when waiting for approval, otherwise last activity
                if isWaitingForApproval, let toolName = session.pendingToolName {
                    // Show tool name in amber + input on same line
                    HStack(spacing: 4) {
                        Text(MCPToolFormatter.formatToolName(toolName))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(TerminalColors.amber.opacity(0.9))
                        if isInteractiveTool {
                            Text("Needs your input")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        } else if let input = session.pendingToolInput {
                            Text(input)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                } else if let role = session.lastMessageRole {
                    switch role {
                    case "tool":
                        // Tool call - show tool name + input
                        HStack(spacing: 4) {
                            if let toolName = session.lastToolName {
                                Text(MCPToolFormatter.formatToolName(toolName))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            if let input = session.lastMessage {
                                Text(input)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    case "user":
                        // User message - prefix with "You:"
                        HStack(spacing: 4) {
                            Text("You:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                            if let msg = session.lastMessage {
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    default:
                        // Assistant message - just show text
                        if let msg = session.lastMessage {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                    }
                } else if let lastMsg = session.lastMessage {
                    Text(lastMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Action icons or approval buttons
            if isWaitingForApproval && isInteractiveTool {
                // Interactive tools like AskUserQuestion - show terminal button
                HStack(spacing: 8) {
                    if canFocusTerminal {
                        TerminalButton(
                            isEnabled: canFocusTerminal,
                            onTap: { onFocus() }
                        )
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isWaitingForApproval {
                InlineApprovalButtons(
                    onApprove: onApprove,
                    onReject: onReject
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                HStack(spacing: 8) {
                    // Jump to terminal window (prefers Ghostty when available)
                    if canFocusTerminal {
                        IconButton(icon: "terminal") {
                            onFocus()
                        }
                    }

                    // Archive button - only for idle or completed sessions
                    if session.phase == .idle || session.phase == .waitingForInput {
                        IconButton(icon: "archivebox") {
                            onArchive()
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onChat()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch session.phase {
        case .processing, .compacting:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(claudeOrange)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForApproval:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(TerminalColors.amber)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForInput:
            Circle()
                .fill(TerminalColors.green)
                .frame(width: 6, height: 6)
        case .idle, .ended:
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

}

private struct ActiveSessionCard: View {
    let session: SessionState
    let onFocus: () -> Void

    @State private var isHovered = false

    private var canFocusTerminal: Bool {
        session.pid != nil || !session.cwd.isEmpty
    }

    private var statusLabel: String {
        switch session.phase {
        case .processing: return "Running"
        case .compacting: return "Compacting"
        case .waitingForApproval: return "Approval"
        case .waitingForInput: return "Waiting"
        case .idle: return "Idle"
        case .ended: return "Ended"
        }
    }

    private var statusTint: Color {
        switch session.phase {
        case .processing, .compacting:
            return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .waitingForApproval:
            return TerminalColors.amber
        case .waitingForInput:
            return TerminalColors.green
        case .idle, .ended:
            return .white
        }
    }

    private var currentToolLabel: String? {
        if let pending = session.pendingToolName {
            return MCPToolFormatter.formatToolName(pending)
        }
        if let lastTool = session.lastToolName, session.lastMessageRole == "tool" {
            return MCPToolFormatter.formatToolName(lastTool)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(statusTint.opacity(session.phase == .idle ? 0.25 : 0.95))
                    .frame(width: 7, height: 7)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(session.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.95))
                            .lineLimit(1)

                        CompactMetadataPill(label: statusLabel, tint: statusTint.opacity(0.9))
                        CompactMetadataPill(label: session.isInTmux ? "tmux" : "plain", tint: session.isInTmux ? Color(red: 0.45, green: 0.72, blue: 0.95) : .white.opacity(0.7))
                        CompactMetadataPill(label: SessionMetadataFormatter.runtimeString(since: session.createdAt), tint: .white.opacity(0.85))
                    }

                    Text(session.cwd)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                if canFocusTerminal {
                    IconButton(icon: "terminal") {
                        onFocus()
                    }
                }
            }

            HStack(spacing: 10) {
                SessionInfoLine(label: "Project", value: session.projectName)
                if let pid = session.pid {
                    SessionInfoLine(label: "PID", value: "\(pid)")
                }
                if let tty = session.tty, !tty.isEmpty {
                    SessionInfoLine(label: "TTY", value: tty)
                }
                if let tool = currentToolLabel {
                    SessionInfoLine(label: "Tool", value: tool)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isHovered ? Color.white.opacity(0.075) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(isHovered ? 0.08 : 0.04), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { isHovered = $0 }
    }
}

private struct CompactMetadataPill: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.06))
            )
    }
}

private struct SessionInfoLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.36))

            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.62))
                .lineLimit(1)
        }
    }
}

private enum SessionMetadataFormatter {
    static func runtimeString(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, remainingSeconds)
        }
        return "\(remainingSeconds)s"
    }
}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var showDenyButton = false
    @State private var showAllowButton = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                onReject()
            } label: {
                Text("Deny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? .white.opacity(0.8) : .white.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isEnabled ? .black : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
