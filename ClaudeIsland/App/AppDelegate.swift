import AppKit
import IOKit
import Mixpanel
import os.log
import Sparkle
import SwiftUI

private let appLogger = Logger(subsystem: "com.claudeisland", category: "AppLifecycle")

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var updateCheckTimer: Timer?
    private var isShuttingDown = false
    private var forcedTerminationWorkItem: DispatchWorkItem?

    static var shared: AppDelegate?
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

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

        Mixpanel.initialize(token: "49814c1436104ed108f3fc4735228496")

        let distinctId = getOrCreateDistinctId()
        Mixpanel.mainInstance().identify(distinctId: distinctId)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersionString

        Mixpanel.mainInstance().registerSuperProperties([
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        fetchAndRegisterClaudeVersion()

        Mixpanel.mainInstance().people.set(properties: [
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        Mixpanel.mainInstance().track(event: "App Launched")
        Mixpanel.mainInstance().flush()

        HookInstaller.installIfNeeded()
        NSApplication.shared.setActivationPolicy(.accessory)

        windowManager = WindowManager()
        appLogger.info("Creating initial notch window")
        _ = windowManager?.setupNotchWindow()

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let updater = self?.updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdates()
        }
    }

    private func handleScreenChange() {
        guard !isShuttingDown else {
            appLogger.debug("Ignoring screen change while shutting down")
            return
        }

        appLogger.info("Handling screen change by recreating notch window")
        _ = windowManager?.setupNotchWindow()
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
        Mixpanel.mainInstance().flush()
    }

    private func performShutdown() {
        guard isShuttingDown || windowManager != nil || screenObserver != nil || updateCheckTimer != nil else {
            appLogger.debug("performShutdown ignored because shutdown already completed")
            return
        }

        appLogger.info("Performing shutdown")
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil

        screenObserver = nil

        HookSocketServer.shared.stop()

        Task { @MainActor in
            InterruptWatcherManager.shared.stopAll()
            AgentFileWatcherManager.shared.stopAll()
        }

        EventMonitors.shared.stopAll()

        windowManager?.shutdown()
        windowManager = nil
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

    private func getOrCreateDistinctId() -> String {
        let key = "mixpanel_distinct_id"

        if let existingId = UserDefaults.standard.string(forKey: key) {
            return existingId
        }

        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        if let uuid = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            UserDefaults.standard.set(uuid, forKey: key)
            return uuid
        }

        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
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

            Mixpanel.mainInstance().registerSuperProperties(["claude_code_version": version])
            Mixpanel.mainInstance().people.set(properties: ["claude_code_version": version])
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
}
