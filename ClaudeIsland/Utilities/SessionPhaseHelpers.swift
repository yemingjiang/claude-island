//
//  SessionPhaseHelpers.swift
//  ClaudeIsland
//
//  Helper functions for session phase display
//

import SwiftUI

struct SessionPhaseHelpers {
    /// Get color for session phase
    static func phaseColor(for phase: SessionPhase) -> Color {
        switch phase {
        case .waitingForInput:
            return TerminalColors.green
        case .processing:
            return TerminalColors.cyan
        case .idle, .ended:
            return TerminalColors.dim
        case .waitingForApproval, .compacting:
            return TerminalColors.dim
        }
    }

    /// Get description for session phase
    static func phaseDescription(for phase: SessionPhase) -> String {
        switch phase {
        case .waitingForInput:
            return "Ready for input"
        case .processing:
            return "Running..."
        case .idle:
            return "Idle"
        case .ended:
            return "Ended"
        case .waitingForApproval, .compacting:
            return "Idle"
        }
    }

    /// Format time ago string
    static func timeAgo(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
