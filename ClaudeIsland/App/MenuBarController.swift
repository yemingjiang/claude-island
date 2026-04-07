//
//  MenuBarController.swift
//  ClaudeIsland
//
//  Standard macOS menu bar entry point for Claude Island.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let sessionMonitor: ClaudeSessionMonitor
    private let viewModel: NotchViewModel
    private let panel: MenuBarPanel
    private let hostingController: NSHostingController<MenuBarPopoverView>
    private var cancellables = Set<AnyCancellable>()
    private var closeMonitor: EventMonitor?

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.sessionMonitor = ClaudeSessionMonitor()
        self.viewModel = MenuBarController.makeViewModel()
        self.hostingController = NSHostingController(
            rootView: MenuBarPopoverView(
                viewModel: viewModel,
                sessionMonitor: sessionMonitor
            )
        )
        self.panel = MenuBarPanel(contentRect: NSRect(origin: .zero, size: viewModel.openedSize))
        super.init()

        configureStatusItem()
        configurePanel()
        bindState()

        sessionMonitor.startMonitoring()
        viewModel.updateInstancesLayout(using: sessionMonitor.instances)
        refreshStatusIcon()
        refreshPanelLayout()
    }

    func shutdown() {
        closePanel()
        closeMonitor?.stop()
        cancellables.removeAll()
        sessionMonitor.stopMonitoring()

        if let button = statusItem.button {
            button.target = nil
            button.action = nil
        }

        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func openPanelForAutomation() {
        if !panel.isVisible {
            viewModel.notchOpen(reason: .click)
            refreshPanelLayout()
            panel.makeKeyAndOrderFront(nil)
            startCloseMonitor()
        } else {
            refreshPanelLayout()
            panel.orderFrontRegardless()
        }
    }

    func showMenuForAutomation() {
        openPanelForAutomation()
        viewModel.showMenu()
        refreshPanelLayout()
        panel.orderFrontRegardless()
    }

    func showInstancesForAutomation() {
        openPanelForAutomation()
        viewModel.showInstances()
        refreshPanelLayout()
        panel.orderFrontRegardless()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Claude Island"
    }

    private func configurePanel() {
        panel.contentViewController = hostingController
        panel.orderOut(nil)
    }

    private func bindState() {
        sessionMonitor.$instances
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                self.viewModel.updateInstancesLayout(using: sessions)
                self.refreshStatusIcon(using: sessions)
                self.schedulePanelLayoutRefresh()
            }
            .store(in: &cancellables)

        UpdateManager.shared.$hasUnseenUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatusIcon()
            }
            .store(in: &cancellables)

        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.schedulePanelLayoutRefresh()
            }
            .store(in: &cancellables)
    }

    private func schedulePanelLayoutRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshPanelLayout()
        }
    }

    private func refreshPanelLayout() {
        let size = viewModel.openedSize
        hostingController.view.frame = NSRect(origin: .zero, size: size)

        guard let frame = targetPanelFrame(for: size) else { return }
        panel.setFrame(frame, display: true)
    }

    private func refreshStatusIcon(using sessions: [SessionState]? = nil) {
        guard let button = statusItem.button else { return }

        let state = indicatorState(
            for: sessions ?? sessionMonitor.instances,
            hasUnseenUpdate: UpdateManager.shared.hasUnseenUpdate
        )
        button.image = makeStatusImage(for: state)
    }

    private func indicatorState(
        for sessions: [SessionState],
        hasUnseenUpdate: Bool
    ) -> MenuBarIndicatorState {
        if sessions.contains(where: { $0.phase == .waitingForInput }) {
            return .waiting
        }

        if sessions.contains(where: { $0.phase.isActive }) {
            return .running
        }

        if hasUnseenUpdate {
            return .update
        }

        return .idle
    }

    private func makeStatusImage(for state: MenuBarIndicatorState) -> NSImage? {
        let renderer = ImageRenderer(content: MenuBarStatusIcon(state: state))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let image = renderer.nsImage else { return nil }
        image.size = NSSize(width: 20, height: 18)
        image.isTemplate = false
        return image
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        if panel.isVisible {
            closePanel()
            return
        }

        viewModel.notchOpen(reason: .click)
        refreshPanelLayout()
        panel.makeKeyAndOrderFront(sender)
        startCloseMonitor()
    }

    private static func makeViewModel() -> NotchViewModel {
        ScreenSelector.shared.refreshScreens()

        let fallbackRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screen = ScreenSelector.shared.selectedScreen ?? NSScreen.main ?? NSScreen.screens.first
        let screenRect = screen?.frame ?? fallbackRect
        let notchSize = screen?.notchSize ?? CGSize(width: 224, height: 38)
        let deviceNotchRect = CGRect(
            x: (screenRect.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height
        )

        return NotchViewModel(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: screenRect.height,
            hasPhysicalNotch: screen?.hasPhysicalNotch ?? false,
            enableGlobalEventHandling: false
        )
    }

    private func closePanel() {
        panel.orderOut(nil)
        stopCloseMonitor()
        viewModel.notchClose()
    }

    private func startCloseMonitor() {
        if closeMonitor == nil {
            closeMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                self?.handleMonitoredEvent(event)
            }
        }
        closeMonitor?.start()
    }

    private func stopCloseMonitor() {
        closeMonitor?.stop()
    }

    private func handleMonitoredEvent(_ event: NSEvent) {
        guard panel.isVisible else { return }

        if event.type == .keyDown, event.keyCode == 53 {
            closePanel()
            return
        }

        guard event.type == .leftMouseDown || event.type == .rightMouseDown else {
            return
        }

        let clickLocation = NSEvent.mouseLocation
        if panel.frame.contains(clickLocation) {
            return
        }

        if let buttonFrame = statusButtonScreenFrame(), buttonFrame.contains(clickLocation) {
            return
        }

        closePanel()
    }

    private func targetPanelFrame(for size: CGSize) -> NSRect? {
        guard let buttonFrame = statusButtonScreenFrame() else { return nil }
        let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.frame ?? .zero

        let originX = min(
            max(buttonFrame.midX - size.width / 2, visibleFrame.minX + 8),
            visibleFrame.maxX - size.width - 8
        )
        let originY = buttonFrame.minY - size.height - 8

        return NSRect(
            x: round(originX),
            y: round(originY),
            width: size.width,
            height: size.height
        )
    }

    private func statusButtonScreenFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let rectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }
}

private final class MenuBarPanel: NSPanel {
    convenience init(contentRect: NSRect) {
        self.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.transient, .moveToActiveSpace, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum MenuBarIndicatorState {
    case idle
    case running
    case waiting
    case approval
    case update
}

private struct MenuBarStatusIcon: View {
    let state: MenuBarIndicatorState

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ClaudeCrabIcon(
                size: 14,
                color: crabColor
            )
            .frame(width: 20, height: 18)

            if let badgeColor {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.7), lineWidth: 0.5)
                    )
                    .offset(x: -1, y: 1)
            }
        }
        .frame(width: 20, height: 18)
    }

    private var crabColor: Color {
        switch state {
        case .waiting, .approval:
            return TerminalColors.red
        case .idle, .running, .update:
            return Color(red: 0.85, green: 0.47, blue: 0.34)
        }
    }

    private var badgeColor: Color? {
        switch state {
        case .idle:
            return nil
        case .running:
            return TerminalColors.amber
        case .waiting:
            return nil
        case .approval:
            return TerminalColors.red
        case .update:
            return TerminalColors.blue
        }
    }
}
