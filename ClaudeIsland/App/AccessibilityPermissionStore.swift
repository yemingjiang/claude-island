import ApplicationServices
import Combine
import Foundation
import os.log

private let accessibilityLogger = Logger(subsystem: "com.claudeisland", category: "Accessibility")

@MainActor
final class AccessibilityPermissionStore: ObservableObject {
    static let shared = AccessibilityPermissionStore()

    @Published private(set) var isEnabled = false

    private init() {}

    func refresh() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let newValue = AXIsProcessTrustedWithOptions(options)

        if newValue != isEnabled {
            accessibilityLogger.info("Accessibility permission updated to \(newValue, privacy: .public)")
        }

        isEnabled = newValue
    }
}
