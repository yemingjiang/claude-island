//
//  MenuBarPopoverView.swift
//  ClaudeIsland
//
//  Popover content hosted from the macOS menu bar status item.
//

import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject private var updateManager = UpdateManager.shared

    private let contentHorizontalPadding: CGFloat = 16

    private var hasWaitingForInput: Bool {
        sessionMonitor.instances.contains(where: { $0.phase == .waitingForInput })
    }

    private var isProcessing: Bool {
        sessionMonitor.instances.contains(where: { $0.phase.isActive })
    }

    private var statusLabel: (text: String, color: Color)? {
        if hasWaitingForInput {
            return ("Reply needed", TerminalColors.red)
        }

        if isProcessing {
            return ("Running", TerminalColors.amber)
        }

        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(Color.white.opacity(0.08))

            Group {
                switch viewModel.contentType {
                case .instances:
                    ClaudeInstancesView(
                        sessionMonitor: sessionMonitor,
                        viewModel: viewModel
                    )
                case .menu:
                    NotchMenuView(viewModel: viewModel)
                case .chat(let session):
                    ChatView(
                        sessionId: session.sessionId,
                        initialSession: session,
                        sessionMonitor: sessionMonitor,
                        viewModel: viewModel
                    )
                }
            }
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(
            width: viewModel.openedSize.width,
            height: viewModel.openedSize.height,
            alignment: .top
        )
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ClaudeCrabIcon(
                size: 16,
                color: hasWaitingForInput
                    ? TerminalColors.red
                    : Color(red: 0.95, green: 0.68, blue: 0.55),
                animateLegs: isProcessing
            )
            .frame(width: 24, height: 18, alignment: .leading)

            if let statusLabel {
                Text(statusLabel.text.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(statusLabel.color.opacity(0.95))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(statusLabel.color.opacity(0.14))
                    )
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 24, height: 24)

                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}
