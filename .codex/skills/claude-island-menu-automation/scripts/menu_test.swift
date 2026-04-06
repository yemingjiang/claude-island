#!/usr/bin/env swift

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum MenuTestError: Error, LocalizedError {
    case invalidArguments(String)
    case appNotRunning(String)
    case screenUnavailable
    case menuButtonNotFound
    case quitButtonNotFound
    case quitDidNotExit(observedSeconds: Double)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .appNotRunning(let bundleID):
            return "Claude Island is not running for bundle id \(bundleID). Use --launch or start the app first."
        case .screenUnavailable:
            return "No main screen available."
        case .menuButtonNotFound:
            return "Could not find the top-right menu button owned by Claude Island."
        case .quitButtonNotFound:
            return "Could not find the Quit button in the opened menu."
        case .quitDidNotExit(let observedSeconds):
            return "Quit was triggered but the app was still running after \(observedSeconds)s."
        }
    }
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
    let description: String
    let role: String
}

struct ScreenGeometry {
    let width: CGFloat
    let height: CGFloat
    let notchWidth: CGFloat
    let menuWidth: CGFloat
    let menuHeight: CGFloat
    let notchCenterX: CGFloat
    let notchClickY: CGFloat
    let scanMinX: Int
    let scanMaxX: Int

    init(screen: NSScreen) {
        let frame = screen.frame
        let safeTop = screen.safeAreaInsets.top
        let leftPadding = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = screen.auxiliaryTopRightArea?.width ?? 0

        let notchWidth: CGFloat
        if safeTop > 0, leftPadding > 0, rightPadding > 0 {
            notchWidth = frame.width - leftPadding - rightPadding + 4
        } else if safeTop > 0 {
            notchWidth = 180
        } else {
            notchWidth = 224
        }

        let menuWidth = min(frame.width * 0.4, 480) + 62
        let menuHeight: CGFloat = 460
        let notchCenterX = frame.midX
        let notchTrailingX = notchCenterX + notchWidth / 2
        let menuLeadingX = notchTrailingX - menuWidth

        self.width = frame.width
        self.height = frame.height
        self.notchWidth = notchWidth
        self.menuWidth = menuWidth
        self.menuHeight = menuHeight
        self.notchCenterX = notchCenterX
        self.notchClickY = 20
        self.scanMinX = max(Int(menuLeadingX) + 20, 0)
        self.scanMaxX = min(Int(menuLeadingX + menuWidth) - 20, Int(frame.width) - 1)
    }
}

func printHelp() {
    let help = """
    Usage: menu_test.swift [options]

    Actions:
      --action quit         Open the menu and verify Quit exits the app.
      --action buttons      List visible AX buttons owned by the app.

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
    var index = 1
    let args = CommandLine.arguments

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

func attrString(_ element: AXUIElement, _ name: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return ""
    }
    return value as? String ?? ""
}

func mouseClick(x: Double, y: Double) {
    let point = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(80_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(50_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func buttonHits(pid targetPID: pid_t, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>, step: Int = 10) -> [ButtonHit] {
    var hits: [ButtonHit] = []
    var seen = Set<String>()

    for y in stride(from: yRange.lowerBound, through: yRange.upperBound, by: step) {
        for x in stride(from: xRange.lowerBound, through: xRange.upperBound, by: step) {
            guard let element = elementAtPosition(x: Float(x), y: Float(y)),
                  pid(of: element) == targetPID else {
                continue
            }

            let role = attrString(element, kAXRoleAttribute)
            guard role == "AXButton" else { continue }

            let description = attrString(element, kAXDescriptionAttribute)
            let key = "\(x):\(y):\(description):\(role)"
            guard seen.insert(key).inserted else { continue }

            hits.append(ButtonHit(x: x, y: y, description: description, role: role))
        }
    }

    return hits
}

func notchOpenIfNeeded(geometry: ScreenGeometry) {
    mouseClick(x: geometry.notchCenterX, y: geometry.notchClickY)
    Thread.sleep(forTimeInterval: 0.8)
}

func findMenuButton(pid targetPID: pid_t, geometry: ScreenGeometry) -> ButtonHit? {
    let hits = buttonHits(
        pid: targetPID,
        xRange: max(Int(geometry.notchCenterX) - 120, 0)...min(Int(geometry.width) - 1, geometry.scanMaxX + 120),
        yRange: 4...50,
        step: 4
    )

    let preferred = hits.filter { ["Close", "Drag"].contains($0.description) }
    return (preferred.isEmpty ? hits : preferred).max(by: { $0.x < $1.x })
}

func findQuitButton(pid targetPID: pid_t, geometry: ScreenGeometry) -> ButtonHit? {
    let hits = buttonHits(
        pid: targetPID,
        xRange: geometry.scanMinX...geometry.scanMaxX,
        yRange: 40...Int(geometry.menuHeight + 20)
    )

    return hits.first(where: { $0.description == "Quit" })
}

func axPress(at hit: ButtonHit, targetPID: pid_t) -> AXError {
    guard let element = elementAtPosition(x: Float(hit.x), y: Float(hit.y)),
          pid(of: element) == targetPID else {
        return .invalidUIElement
    }

    return AXUIElementPerformAction(element, kAXPressAction as CFString)
}

func ensureMenuVisible(pid targetPID: pid_t, geometry: ScreenGeometry) throws -> ButtonHit {
    if let quit = findQuitButton(pid: targetPID, geometry: geometry) {
        return quit
    }

    for _ in 0..<3 {
        notchOpenIfNeeded(geometry: geometry)

        if let quit = findQuitButton(pid: targetPID, geometry: geometry) {
            return quit
        }

        if let menuButton = findMenuButton(pid: targetPID, geometry: geometry) {
            _ = axPress(at: menuButton, targetPID: targetPID)
            Thread.sleep(forTimeInterval: 0.8)

            if let quit = findQuitButton(pid: targetPID, geometry: geometry) {
                return quit
            }
        }

        Thread.sleep(forTimeInterval: 0.5)
    }

    if findMenuButton(pid: targetPID, geometry: geometry) == nil {
        throw MenuTestError.menuButtonNotFound
    }

    throw MenuTestError.quitButtonNotFound
}

func run() throws {
    let options = try parseOptions()

    if options.launch, currentApp(bundleID: options.bundleID) == nil {
        try launchApp(at: options.appPath)
    }

    guard let app = waitForApp(bundleID: options.bundleID, timeoutSeconds: 4) else {
        throw MenuTestError.appNotRunning(options.bundleID)
    }

    guard let screen = NSScreen.main else {
        throw MenuTestError.screenUnavailable
    }

    let geometry = ScreenGeometry(screen: screen)
    let pid = app.processIdentifier

    switch options.action {
    case .buttons:
        notchOpenIfNeeded(geometry: geometry)
        let hits = buttonHits(
            pid: pid,
            xRange: geometry.scanMinX...geometry.scanMaxX,
            yRange: 8...Int(geometry.menuHeight + 20)
        )

        let payload: [String: Any] = [
            "status": "ok",
            "action": "buttons",
            "pid": pid,
            "buttons": hits.map {
                [
                    "x": $0.x,
                    "y": $0.y,
                    "description": $0.description,
                    "role": $0.role
                ]
            }
        ]
        emit(payload, json: options.json)

    case .quit:
        let quit = try ensureMenuVisible(pid: pid, geometry: geometry)
        let pressResult = axPress(at: quit, targetPID: pid)
        let exited = waitForExit(bundleID: options.bundleID, timeoutSeconds: options.timeoutSeconds)

        if !exited {
            throw MenuTestError.quitDidNotExit(observedSeconds: options.timeoutSeconds)
        }

        let payload: [String: Any] = [
            "status": "ok",
            "action": "quit",
            "pid_before": pid,
            "quit_button": [
                "x": quit.x,
                "y": quit.y,
                "description": quit.description
            ],
            "ax_press_result": pressResult.rawValue,
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
