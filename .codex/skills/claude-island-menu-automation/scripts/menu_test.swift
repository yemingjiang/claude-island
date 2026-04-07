#!/usr/bin/env swift

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum MenuTestError: Error, LocalizedError {
    case invalidArguments(String)
    case appNotRunning(String)
    case accessibilityNotGranted
    case screenUnavailable
    case statusItemNotFound
    case panelNotFound
    case menuToggleNotFound
    case quitButtonNotFound
    case quitDidNotExit(observedSeconds: Double)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .appNotRunning(let bundleID):
            return "Claude Island is not running for bundle id \(bundleID). Use --launch or start the app first."
        case .accessibilityNotGranted:
            return "Accessibility permission is required for AX-based menu automation."
        case .screenUnavailable:
            return "No main screen available."
        case .statusItemNotFound:
            return "Could not find the top-right menu bar status item owned by Claude Island."
        case .panelNotFound:
            return "Could not detect the Claude Island panel after opening the menu bar entrypoint."
        case .menuToggleNotFound:
            return "Could not find the panel's top-right menu toggle button."
        case .quitButtonNotFound:
            return "Could not find the Quit button in the opened settings menu."
        case .quitDidNotExit(let observedSeconds):
            return "Quit was triggered but the app was still running after \(observedSeconds)s."
        }
    }
}

enum AutomationAction: String {
    case openPanel = "open-panel"
    case showMenu = "show-menu"
    case showInstances = "show-instances"
    case quit = "quit"
}

enum Action: String {
    case quit
    case buttons
}

struct Options {
    var action: Action = .quit
    var appPath: String = "/Applications/Claude Island.app"
    var bundleID: String = "com.celestial.ClaudeIsland"
    var launch = false
    var timeoutSeconds: Double = 8
    var json = false
}

struct ButtonHit {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let title: String
    let description: String
    let role: String
    let subrole: String
    let source: String

    var centerPoint: CGPoint {
        CGPoint(x: Double(x) + Double(width) / 2, y: Double(y) + Double(height) / 2)
    }

    var label: String {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTitle.isEmpty {
            return cleanedTitle
        }

        let cleanedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedDescription.isEmpty {
            return cleanedDescription
        }

        return ""
    }
}

struct WindowSnapshot {
    let frame: CGRect
    let element: AXUIElement
}

struct WindowFrameSnapshot {
    let frame: CGRect
    let layer: Int
    let name: String
}

func printHelp() {
    let help = """
    Usage: menu_test.swift [options]

    Actions:
      --action quit         Trigger the app's quit path through the local automation hook and verify the process exits.
      --action buttons      Open the settings panel and list visible AX buttons discovered there.

    Options:
      --launch              Launch /Applications/Claude Island.app if not already running.
      --app-path PATH       App path. Default: /Applications/Claude Island.app
      --bundle-id ID        Bundle id. Default: com.celestial.ClaudeIsland
      --timeout SECONDS     Exit observation window for quit. Default: 8
      --json                Emit JSON instead of plain text.
      --help                Show this message.

    Examples:
      .codex/skills/claude-island-menu-automation/scripts/menu_test.swift --action quit --launch --json
      .codex/skills/claude-island-menu-automation/scripts/menu_test.swift --action buttons --launch
    """

    print(help)
}

func parseOptions() throws -> Options {
    var options = Options()
    let args = CommandLine.arguments
    var index = 1

    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--action":
            index += 1
            guard index < args.count, let action = Action(rawValue: args[index]) else {
                throw MenuTestError.invalidArguments("Error: --action requires one of: quit, buttons")
            }
            options.action = action
        case "--app-path":
            index += 1
            guard index < args.count else {
                throw MenuTestError.invalidArguments("Error: --app-path requires a value")
            }
            options.appPath = args[index]
        case "--bundle-id":
            index += 1
            guard index < args.count else {
                throw MenuTestError.invalidArguments("Error: --bundle-id requires a value")
            }
            options.bundleID = args[index]
        case "--timeout":
            index += 1
            guard index < args.count, let timeout = Double(args[index]), timeout > 0 else {
                throw MenuTestError.invalidArguments("Error: --timeout requires a positive number")
            }
            options.timeoutSeconds = timeout
        case "--launch":
            options.launch = true
        case "--json":
            options.json = true
        case "--help", "-h":
            printHelp()
            exit(0)
        default:
            throw MenuTestError.invalidArguments("Error: unknown argument \(arg)")
        }
        index += 1
    }

    return options
}

func emit(_ object: [String: Any], json: Bool) {
    if json,
       let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
       let string = String(data: data, encoding: .utf8) {
        print(string)
        return
    }

    for (key, value) in object.sorted(by: { $0.key < $1.key }) {
        print("\(key)=\(value)")
    }
}

func currentApp(bundleID: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .sorted { $0.processIdentifier > $1.processIdentifier }
        .first
}

func launchApp(at appPath: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", appPath]
    try process.run()
    process.waitUntilExit()
}

func waitForApp(bundleID: String, timeoutSeconds: Double) -> NSRunningApplication? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if let app = currentApp(bundleID: bundleID) {
            return app
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return nil
}

func waitForExit(bundleID: String, timeoutSeconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if currentApp(bundleID: bundleID) == nil {
            return true
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return currentApp(bundleID: bundleID) == nil
}

func postAutomationAction(bundleID: String, action: AutomationAction) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.claudeisland.automation"),
        object: bundleID,
        userInfo: ["action": action.rawValue],
        deliverImmediately: true
    )
}

func ensureAccessibilityGranted() throws {
    if !AXIsProcessTrusted() {
        throw MenuTestError.accessibilityNotGranted
    }
}

func elementAtPosition(x: Float, y: Float) -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, x, y, &element) == .success else {
        return nil
    }
    return element
}

func pid(of element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return pid
}

func attributeValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func attrString(_ element: AXUIElement, _ name: String) -> String {
    attributeValue(element, name) as? String ?? ""
}

func attrCGPoint(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let value = attributeValue(element, name) else { return nil }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
    return point
}

func attrCGSize(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let value = attributeValue(element, name) else { return nil }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
    return size
}

func frame(of element: AXUIElement) -> CGRect? {
    guard let origin = attrCGPoint(element, kAXPositionAttribute),
          let size = attrCGSize(element, kAXSizeAttribute) else {
        return nil
    }
    return CGRect(origin: origin, size: size)
}

func childElements(of element: AXUIElement) -> [AXUIElement] {
    attributeValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func mouseClick(at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(80_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(50_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func axPress(_ element: AXUIElement) -> AXError {
    AXUIElementPerformAction(element, kAXPressAction as CFString)
}

func onScreenWindowFrames(ownerPID: pid_t) -> [WindowFrameSnapshot] {
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    return info.compactMap { entry in
        guard let pidNumber = entry[kCGWindowOwnerPID as String] as? NSNumber,
              pidNumber.int32Value == ownerPID,
              let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let layerNumber = entry[kCGWindowLayer as String] as? NSNumber else {
            return nil
        }

        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDictionary, &rect), !rect.isEmpty else {
            return nil
        }

        return WindowFrameSnapshot(
            frame: rect,
            layer: layerNumber.intValue,
            name: entry[kCGWindowName as String] as? String ?? ""
        )
    }
}

func dedupeKey(for hit: ButtonHit) -> String {
    "\(hit.x):\(hit.y):\(hit.width):\(hit.height):\(hit.label):\(hit.role):\(hit.source)"
}

func buttonHit(
    for element: AXUIElement,
    source: String,
    allowedRoles: Set<String> = ["AXButton"]
) -> ButtonHit? {
    guard let elementFrame = frame(of: element) else {
        return nil
    }

    let role = attrString(element, kAXRoleAttribute)
    guard allowedRoles.contains(role) else { return nil }

    return ButtonHit(
        x: Int(elementFrame.origin.x.rounded()),
        y: Int(elementFrame.origin.y.rounded()),
        width: Int(elementFrame.size.width.rounded()),
        height: Int(elementFrame.size.height.rounded()),
        title: attrString(element, kAXTitleAttribute),
        description: attrString(element, kAXDescriptionAttribute),
        role: role,
        subrole: attrString(element, kAXSubroleAttribute),
        source: source
    )
}

func recursiveButtons(in element: AXUIElement, source: String, limit: Int = 200) -> [ButtonHit] {
    var results: [ButtonHit] = []
    var queue: [AXUIElement] = [element]
    var visited = Set<String>()

    while !queue.isEmpty, results.count < limit {
        let current = queue.removeFirst()
        let role = attrString(current, kAXRoleAttribute)
        let visitKey = "\(role):\(String(describing: frame(of: current)))"
        if !visited.insert(visitKey).inserted {
            continue
        }

        if let hit = buttonHit(for: current, source: source) {
            results.append(hit)
        }

        queue.append(contentsOf: childElements(of: current))
    }

    return results
}

func statusItemCandidates(for targetPID: pid_t, screen: NSScreen) -> [ButtonHit] {
    let width = Int(screen.frame.width)
    let height = Int(screen.frame.height)
    let xStart = max(width - 420, 0)
    var hits: [ButtonHit] = []
    var seen = Set<String>()
    let yBands: [ClosedRange<Int>] = [2...36, max(height - 36, 0)...max(height - 2, 0)]

    for yBand in yBands {
        for y in stride(from: yBand.lowerBound, through: yBand.upperBound, by: 2) {
            for x in stride(from: xStart, through: width - 1, by: 4) {
                guard let element = elementAtPosition(x: Float(x), y: Float(y)),
                      pid(of: element) == targetPID,
                      let hit = buttonHit(
                        for: element,
                        source: "status-item",
                        allowedRoles: ["AXButton", "AXMenuBarItem"]
                      ) else {
                    continue
                }

                let key = dedupeKey(for: hit)
                if seen.insert(key).inserted {
                    hits.append(hit)
                }
            }
        }
    }

    return hits.sorted {
        if $0.x == $1.x { return $0.y < $1.y }
        return $0.x > $1.x
    }
}

func statusItemFrame(for targetPID: pid_t, screen: NSScreen) -> CGRect? {
    let maxTopOffset: CGFloat = 48
    let candidates = onScreenWindowFrames(ownerPID: targetPID).filter { snapshot in
        let frame = snapshot.frame
        let smallEnough = frame.width <= 44 && frame.height <= 32
        let nearRightEdge = frame.maxX >= screen.frame.width - 240
        let nearTopEdge = frame.minY <= maxTopOffset
        return smallEnough && nearRightEdge && nearTopEdge
    }

    return candidates.sorted {
        if $0.frame.maxX == $1.frame.maxX {
            return ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
        }
        return $0.frame.maxX > $1.frame.maxX
    }.first?.frame
}

func appWindows(pid: pid_t) -> [WindowSnapshot] {
    let app = AXUIElementCreateApplication(pid)
    guard let rawWindows = attributeValue(app, kAXWindowsAttribute) as? [AXUIElement] else {
        return []
    }

    return rawWindows.compactMap { window in
        guard let frame = frame(of: window), !frame.isEmpty else { return nil }
        return WindowSnapshot(frame: frame, element: window)
    }
}

func panelFrame(pid: pid_t) -> CGRect? {
    onScreenWindowFrames(ownerPID: pid)
        .filter { $0.frame.width >= 220 && $0.frame.height >= 160 }
        .sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
        .first?
        .frame
}

func panelButtons(pid targetPID: pid_t) -> [ButtonHit] {
    guard let panelFrame = panelFrame(pid: targetPID) else {
        return []
    }

    var results: [ButtonHit] = []
    var seen = Set<String>()

    let minX = max(Int(panelFrame.minX.rounded()) + 8, 0)
    let maxX = Int(panelFrame.maxX.rounded()) - 8
    let minY = max(Int(panelFrame.minY.rounded()) + 8, 0)
    let maxY = Int(panelFrame.maxY.rounded()) - 8

    guard minX < maxX, minY < maxY else {
        return []
    }

    for y in stride(from: minY, through: maxY, by: 24) {
        for x in stride(from: minX, through: maxX, by: 24) {
            guard let element = elementAtPosition(x: Float(x), y: Float(y)),
                  pid(of: element) == targetPID,
                  let hit = buttonHit(for: element, source: "panel") else {
                continue
            }

            let key = dedupeKey(for: hit)
            if seen.insert(key).inserted {
                results.append(hit)
            }
        }
    }

    let sortedResults = results.sorted {
        if $0.y == $1.y { return $0.x < $1.x }
        return $0.y < $1.y
    }

    if !sortedResults.isEmpty {
        return sortedResults
    }

    var fallback: [ButtonHit] = []
    var seenFallback = Set<String>()
    for window in appWindows(pid: targetPID) {
        for hit in recursiveButtons(in: window.element, source: "panel-ax") {
            let key = dedupeKey(for: hit)
            if seenFallback.insert(key).inserted {
                fallback.append(hit)
            }
        }
    }

    return fallback.sorted {
        if $0.y == $1.y { return $0.x < $1.x }
        return $0.y < $1.y
    }
}

func findQuitButton(pid: pid_t) -> ButtonHit? {
    panelButtons(pid: pid).first {
        let label = $0.label.lowercased()
        return label == "quit" || label.contains("quit")
    }
}

func panelHeaderCandidates(pid: pid_t) -> [ButtonHit] {
    guard let windowFrame = panelFrame(pid: pid) else {
        return []
    }

    let candidates = panelButtons(pid: pid).filter { hit in
        let hitFrame = CGRect(x: hit.x, y: hit.y, width: hit.width, height: hit.height)
        let distanceToTop = abs(windowFrame.maxY - hitFrame.maxY)
        let distanceToBottom = abs(hitFrame.minY - windowFrame.minY)
        let nearestHorizontalEdge = min(distanceToTop, distanceToBottom)
        return nearestHorizontalEdge <= 72
    }

    return candidates.sorted {
        if $0.x == $1.x { return $0.y < $1.y }
        return $0.x > $1.x
    }
}

func waitForPanel(pid: pid_t, timeoutSeconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let hasAXWindow = !appWindows(pid: pid).isEmpty
        let hasWindowListPanel = onScreenWindowFrames(ownerPID: pid).contains {
            $0.frame.width >= 220 && $0.frame.height >= 160
        }
        if hasAXWindow || hasWindowListPanel {
            return true
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    let hasAXWindow = !appWindows(pid: pid).isEmpty
    let hasWindowListPanel = onScreenWindowFrames(ownerPID: pid).contains {
        $0.frame.width >= 220 && $0.frame.height >= 160
    }
    return hasAXWindow || hasWindowListPanel
}

func openPanelIfNeeded(targetPID: pid_t, screen: NSScreen, bundleID: String) throws -> ButtonHit {
    if (panelFrame(pid: targetPID) != nil || !appWindows(pid: targetPID).isEmpty),
       let existing = statusItemCandidates(for: targetPID, screen: screen).first {
        return existing
    }

    postAutomationAction(bundleID: bundleID, action: .showMenu)
    if waitForPanel(pid: targetPID, timeoutSeconds: 4.5) {
        if let statusFrame = statusItemFrame(for: targetPID, screen: screen) {
            return ButtonHit(
                x: Int(statusFrame.origin.x.rounded()),
                y: Int(statusFrame.origin.y.rounded()),
                width: Int(statusFrame.size.width.rounded()),
                height: Int(statusFrame.size.height.rounded()),
                title: "",
                description: "",
                role: "AXMenuBarItem",
                subrole: "",
                source: "automation-show-menu"
            )
        }
        if let panel = panelFrame(pid: targetPID) {
            return ButtonHit(
                x: Int(panel.origin.x.rounded()),
                y: Int(panel.origin.y.rounded()),
                width: Int(panel.size.width.rounded()),
                height: Int(panel.size.height.rounded()),
                title: "",
                description: "",
                role: "AXWindow",
                subrole: "",
                source: "automation-show-menu"
            )
        }
    }

    if let statusItem = statusItemCandidates(for: targetPID, screen: screen).first {
        if let element = elementAtPosition(x: Float(statusItem.centerPoint.x), y: Float(statusItem.centerPoint.y)),
           pid(of: element) == targetPID {
            let pressResult = axPress(element)
            if pressResult != .success {
                mouseClick(at: statusItem.centerPoint)
            }
        } else {
            mouseClick(at: statusItem.centerPoint)
        }

        guard waitForPanel(pid: targetPID, timeoutSeconds: 4.5) else {
            throw MenuTestError.panelNotFound
        }

        return statusItem
    }

    guard let statusFrame = statusItemFrame(for: targetPID, screen: screen) else {
        throw MenuTestError.statusItemNotFound
    }

    let syntheticHit = ButtonHit(
        x: Int(statusFrame.origin.x.rounded()),
        y: Int(statusFrame.origin.y.rounded()),
        width: Int(statusFrame.size.width.rounded()),
        height: Int(statusFrame.size.height.rounded()),
        title: "",
        description: "",
        role: "AXMenuBarItem",
        subrole: "",
        source: "status-window"
    )

    mouseClick(at: syntheticHit.centerPoint)

    guard waitForPanel(pid: targetPID, timeoutSeconds: 4.5) else {
        throw MenuTestError.panelNotFound
    }

    return syntheticHit
}

func ensureSettingsMenuVisible(targetPID: pid_t, screen: NSScreen, bundleID: String) throws -> ButtonHit {
    _ = try openPanelIfNeeded(targetPID: targetPID, screen: screen, bundleID: bundleID)

    postAutomationAction(bundleID: bundleID, action: .showMenu)
    Thread.sleep(forTimeInterval: 1.2)

    if let quit = findQuitButton(pid: targetPID) {
        return quit
    }

    let candidates = panelHeaderCandidates(pid: targetPID).filter {
        !$0.label.lowercased().contains("quit")
    }

    for candidate in candidates.prefix(4) {
        guard let element = elementAtPosition(x: Float(candidate.centerPoint.x), y: Float(candidate.centerPoint.y)),
              pid(of: element) == targetPID else {
            continue
        }

        let pressResult = axPress(element)
        if pressResult != .success {
            mouseClick(at: candidate.centerPoint)
        }

        Thread.sleep(forTimeInterval: 1.2)
        if let quit = findQuitButton(pid: targetPID) {
            return quit
        }
    }

    if candidates.isEmpty {
        throw MenuTestError.menuToggleNotFound
    }

    throw MenuTestError.quitButtonNotFound
}

func run() throws {
    let options = try parseOptions()
    try ensureAccessibilityGranted()

    if options.launch, currentApp(bundleID: options.bundleID) == nil {
        try launchApp(at: options.appPath)
    }

    guard let app = waitForApp(bundleID: options.bundleID, timeoutSeconds: 4) else {
        throw MenuTestError.appNotRunning(options.bundleID)
    }

    guard let screen = NSScreen.main else {
        throw MenuTestError.screenUnavailable
    }

    let targetPID = app.processIdentifier

    switch options.action {
    case .buttons:
        let statusItem = try openPanelIfNeeded(targetPID: targetPID, screen: screen, bundleID: options.bundleID)
        postAutomationAction(bundleID: options.bundleID, action: .showMenu)
        Thread.sleep(forTimeInterval: 1.2)
        let buttons = panelButtons(pid: targetPID)
        let payload: [String: Any] = [
            "status": "ok",
            "action": "buttons",
            "pid": targetPID,
            "status_item": [
                "x": statusItem.x,
                "y": statusItem.y,
                "width": statusItem.width,
                "height": statusItem.height,
                "label": statusItem.label
            ],
            "buttons": buttons.map {
                [
                    "x": $0.x,
                    "y": $0.y,
                    "width": $0.width,
                    "height": $0.height,
                    "title": $0.title,
                    "description": $0.description,
                    "label": $0.label,
                    "source": $0.source
                ]
            }
        ]
        emit(payload, json: options.json)

    case .quit:
        postAutomationAction(bundleID: options.bundleID, action: .quit)

        let exited = waitForExit(bundleID: options.bundleID, timeoutSeconds: options.timeoutSeconds)
        if !exited {
            throw MenuTestError.quitDidNotExit(observedSeconds: options.timeoutSeconds)
        }

        let payload: [String: Any] = [
            "status": "ok",
            "action": "quit",
            "pid_before": targetPID,
            "trigger": "automation-notification",
            "exited": true,
            "observed_seconds": options.timeoutSeconds
        ]
        emit(payload, json: options.json)
    }
}

do {
    try run()
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    fputs("Error: \(message)\n", stderr)
    exit(1)
}
