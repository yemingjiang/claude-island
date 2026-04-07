import AppKit
import Mixpanel
import os.log
import Sparkle
import SwiftUI

private let appLogger = Logger(subsystem: "com.claudeisland", category: "AppLifecycle")

enum Analytics {
    private static let tokenInfoKey = "MixpanelToken"
    private static let distinctIDDefaultsKey = "mixpanel_distinct_id"
    private static var isConfigured = false

    static func configure() {
        guard let token = configuredToken else {
            appLogger.info("Analytics disabled because Mixpanel token is not configured")
            return
        }

        Mixpanel.initialize(token: token, trackAutomaticEvents: false)
        Mixpanel.mainInstance().identify(distinctId: getOrCreateDistinctId())
        isConfigured = true
    }

    static func registerSuperProperties(_ properties: [String: MixpanelType]) {
        guard isConfigured else { return }
        Mixpanel.mainInstance().registerSuperProperties(properties)
    }

    static func setPeopleProperties(_ properties: [String: MixpanelType]) {
        guard isConfigured else { return }
        Mixpanel.mainInstance().people.set(properties: properties)
    }

    static func track(_ event: String) {
        guard isConfigured else { return }
        Mixpanel.mainInstance().track(event: event)
    }

    static func flush() {
        guard isConfigured else { return }
        Mixpanel.mainInstance().flush()
    }

    private static var configuredToken: String? {
        guard let token = Bundle.main.object(forInfoDictionaryKey: tokenInfoKey) as? String else {
            return nil
        }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedToken.isEmpty ? nil : trimmedToken
    }

    private static func getOrCreateDistinctId() -> String {
        if let existingId = UserDefaults.standard.string(forKey: distinctIDDefaultsKey) {
            return existingId
        }

        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: distinctIDDefaultsKey)
        return newId
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private enum AutomationNotification {
        static let name = Notification.Name("com.claudeisland.automation")
        static let actionKey = "action"
        static let openPanel = "open-panel"
        static let showMenu = "show-menu"
        static let showInstances = "show-instances"
        static let quit = "quit"
    }

    private var menuBarController: MenuBarController?
    private var updateCheckTimer: Timer?
    private var isShuttingDown = false
    private var forcedTerminationWorkItem: DispatchWorkItem?
    private var automationObserver: NSObjectProtocol?

    static var shared: AppDelegate?
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver

    override init() {
        userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )
        super.init()
        AppDelegate.shared = self

        do {
            try updater.start()
        } catch {
            print("Failed to start Sparkle updater: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.info("Application did finish launching from \(Bundle.main.bundleURL.path, privacy: .public)")

        if !isLaunchedFromApplications() {
            appLogger.warning("Rejecting launch outside /Applications at \(Bundle.main.bundleURL.path, privacy: .public)")
            print("Claude Island must be launched from /Applications. Exiting duplicate copy at \(Bundle.main.bundleURL.path)")
            NSApplication.shared.terminate(nil)
            return
        }

        if !ensureSingleInstance() {
            appLogger.warning("Rejecting launch because another instance is already running")
            NSApplication.shared.terminate(nil)
            return
        }

        Analytics.configure()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersionString

        Analytics.registerSuperProperties([
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        fetchAndRegisterClaudeVersion()

        Analytics.setPeopleProperties([
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        Analytics.track("App Launched")
        Analytics.flush()

        HookInstaller.installIfNeeded()
        NSApplication.shared.setActivationPolicy(.accessory)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task { @MainActor in
                AccessibilityPermissionStore.shared.refresh()
            }
        }

        appLogger.info("Creating menu bar controller")
        menuBarController = MenuBarController()
        registerAutomationObserver()

        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let updater = self?.updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdates()
        }
    }

    @MainActor
    func requestQuit() {
        guard !isShuttingDown else { return }
        isShuttingDown = true

        appLogger.info("Quit requested from UI")
        performShutdown()
        scheduleForcedTerminationFallback()
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isShuttingDown = true
        appLogger.info("applicationShouldTerminate invoked")
        performShutdown()
        scheduleForcedTerminationFallback()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        isShuttingDown = true
        appLogger.info("applicationWillTerminate invoked")
        forcedTerminationWorkItem?.cancel()
        forcedTerminationWorkItem = nil
        performShutdown()
        Analytics.flush()
    }

    private func performShutdown() {
        guard isShuttingDown || menuBarController != nil || updateCheckTimer != nil else {
            appLogger.debug("performShutdown ignored because shutdown already completed")
            return
        }

        appLogger.info("Performing shutdown")
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil

        HookSocketServer.shared.stop()

        Task { @MainActor in
            InterruptWatcherManager.shared.stopAll()
            AgentFileWatcherManager.shared.stopAll()
        }

        EventMonitors.shared.stopAll()

        if let automationObserver {
            DistributedNotificationCenter.default().removeObserver(automationObserver)
            self.automationObserver = nil
        }

        menuBarController?.shutdown()
        menuBarController = nil
    }

    private func scheduleForcedTerminationFallback() {
        guard forcedTerminationWorkItem == nil else { return }

        let workItem = DispatchWorkItem {
            appLogger.error("Forced termination fallback triggered")
            NSRunningApplication.current.forceTerminate()
        }

        forcedTerminationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func fetchAndRegisterClaudeVersion() {
        let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var latestFile: URL?
        var latestDate: Date?

        for projectDir in projectDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" && !file.lastPathComponent.hasPrefix("agent-") {
                if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = attrs.contentModificationDate {
                    if latestDate == nil || modDate > latestDate! {
                        latestDate = modDate
                        latestFile = file
                    }
                }
            }
        }

        guard let jsonlFile = latestFile,
              let handle = FileHandle(forReadingAtPath: jsonlFile.path) else { return }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 8192)
        guard let content = String(data: data, encoding: .utf8) else { return }

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let version = json["version"] as? String else { continue }

            Analytics.registerSuperProperties(["claude_code_version": version])
            Analytics.setPeopleProperties(["claude_code_version": version])
            return
        }
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.farouqaldori.ClaudeIsland"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                appLogger.warning("Found existing app instance with pid \(existingApp.processIdentifier)")
                existingApp.activate()
            }
            return false
        }

        return true
    }

    private func isLaunchedFromApplications() -> Bool {
        if Foundation.ProcessInfo.processInfo.environment["CLAUDE_ISLAND_ALLOW_NON_APPLICATIONS"] == "1" {
            return true
        }

        let expectedPath = URL(fileURLWithPath: "/Applications/Claude Island.app")
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let actualPath = Bundle.main.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        return actualPath == expectedPath
    }

    private func registerAutomationObserver() {
        automationObserver = DistributedNotificationCenter.default().addObserver(
            forName: AutomationNotification.name,
            object: Bundle.main.bundleIdentifier,
            queue: .main
        ) { [weak self] notification in
            self?.handleAutomationNotification(notification)
        }
    }

    @MainActor
    private func handleAutomationNotification(_ notification: Notification) {
        guard let action = notification.userInfo?[AutomationNotification.actionKey] as? String else {
            return
        }

        switch action {
        case AutomationNotification.openPanel:
            appLogger.info("Automation requested panel open")
            menuBarController?.openPanelForAutomation()
        case AutomationNotification.showMenu:
            appLogger.info("Automation requested settings menu")
            menuBarController?.showMenuForAutomation()
        case AutomationNotification.showInstances:
            appLogger.info("Automation requested instances view")
            menuBarController?.showInstancesForAutomation()
        case AutomationNotification.quit:
            appLogger.info("Automation requested quit")
            requestQuit()
        default:
            appLogger.warning("Ignoring unknown automation action \(action, privacy: .public)")
        }
    }
}
