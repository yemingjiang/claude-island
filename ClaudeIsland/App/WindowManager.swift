//
//  WindowManager.swift
//  ClaudeIsland
//
//  Manages the notch window lifecycle
//

import AppKit
import os.log

/// Logger for window management
private let logger = Logger(subsystem: "com.claudeisland", category: "Window")

class WindowManager {
    private(set) var windowController: NotchWindowController?
    private var isShuttingDown = false

    /// Set up or recreate the notch window
    func setupNotchWindow() -> NotchWindowController? {
        guard !isShuttingDown else {
            logger.debug("Ignoring setupNotchWindow during shutdown")
            return nil
        }

        // Use ScreenSelector for screen selection
        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        guard let screen = screenSelector.selectedScreen else {
            logger.warning("No screen found")
            return nil
        }

        if let existingController = windowController {
            existingController.window?.orderOut(nil)
            existingController.window?.close()
            windowController = nil
        }

        windowController = NotchWindowController(screen: screen)
        windowController?.showWindow(nil)
        logger.info("Displayed notch window on \(screen.localizedName, privacy: .public)")

        return windowController
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true

        logger.info("Shutting down window manager")
        windowController?.window?.orderOut(nil)
        windowController?.window?.close()
        windowController = nil
    }
}
