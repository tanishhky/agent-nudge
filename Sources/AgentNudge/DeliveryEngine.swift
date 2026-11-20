import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation

enum DeliveryError: LocalizedError {
    case accessibilityNotGranted
    case targetNotFound(String)
    case eventSourceUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission not granted — click 'Enable Accessibility' in AgentNudge."
        case .targetNotFound(let detail):
            return detail
        case .eventSourceUnavailable:
            return "Unable to create CGEventSource for typing."
        }
    }
}

struct FocusSnapshot {
    let previousApp: NSRunningApplication?
    let previousTerminalWindowId: Int?
    let previousTerminalTty: String?
}

final class DeliveryEngine: @unchecked Sendable {
    static let shared = DeliveryEngine()

    private let deliveryQueue = DispatchQueue(label: "com.tanishkyadav.agent-nudge.delivery", qos: .userInitiated)

    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func deliverBatch(
        _ timers: [NudgeTimer],
        fallbackExternalApp: NSRunningApplication?,
        closePopoverHandler: @escaping @MainActor () -> Void
    ) async -> [UUID: Result<String, Error>] {
        await MainActor.run {
            closePopoverHandler()
        }

        // Wait slightly for the popover to dismiss cleanly
        try? await Task.sleep(nanoseconds: 120_000_000)

        return await withCheckedContinuation { continuation in
            deliveryQueue.async {
                let results = self.executeBatchSync(timers, fallbackExternalApp: fallbackExternalApp)
                continuation.resume(returning: results)
            }
        }
    }

    private func executeBatchSync(
        _ timers: [NudgeTimer],
        fallbackExternalApp: NSRunningApplication?
    ) -> [UUID: Result<String, Error>] {
        var results: [UUID: Result<String, Error>] = [:]

        guard Self.isAccessibilityTrusted() else {
            for timer in timers {
                results[timer.id] = .failure(DeliveryError.accessibilityNotGranted)
            }
            return results
        }

        // Anti-interruption typing guard: don't steal focus while the user is actively typing
        waitForBriefTypingPause(maxWaitSeconds: 6.0)

        let snapshot = captureFocusSnapshot(fallbackExternalApp: fallbackExternalApp)
        var switchedTerminal = false
        var shouldRestoreAny = false

        for timer in timers {
            if timer.restorePreviousFocus {
                shouldRestoreAny = true
            }

            do {
                if timer.target.kind == .terminalTab {
                    switchedTerminal = true
                }
                try focusTarget(timer.target, snapshot: snapshot)
                usleep(200_000)

                switch timer.deliveryMethod {
                case .typeKeys:
                    try typeText(timer.message, pressEnter: timer.pressEnter)
                case .pasteClipboard:
                    try pasteText(timer.message, pressEnter: timer.pressEnter)
                }

                // Allow target TUI/GUI app to ingest final Return event before changing focus
                usleep(240_000)
                results[timer.id] = .success("Sent at \(TimeFormatting.shortClockTime(Date()))")
            } catch {
                results[timer.id] = .failure(error)
            }
        }

        if shouldRestoreAny {
            restoreFocus(snapshot: snapshot, switchedTerminal: switchedTerminal)
        }

        return results
    }

    private func waitForBriefTypingPause(maxWaitSeconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while Date() < deadline {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            if idle >= 1.2 {
                return
            }
            usleep(250_000)
        }
    }

    private func captureFocusSnapshot(fallbackExternalApp: NSRunningApplication?) -> FocusSnapshot {
        let selfBundle = Bundle.main.bundleIdentifier
        let currentFront = NSWorkspace.shared.frontmostApplication
        let previousApp: NSRunningApplication?
        if let front = currentFront, front.bundleIdentifier != selfBundle {
            previousApp = front
        } else {
            previousApp = fallbackExternalApp
        }

        var prevWinId: Int?
        var prevTty: String?
        if TargetDiscoveryService.isTerminalRunning() {
            let script = """
            const term = Application("Terminal");
            let res = null;
            if (term.running()) {
              const wins = term.windows();
              if (wins.length > 0) {
                const w = wins[0];
                let tty = null;
                try { tty = w.selectedTab.tty(); } catch (e) {}
                res = { windowId: w.id(), tty: tty };
              }
            }
            JSON.stringify(res);
            """
            if let out = TargetDiscoveryService.runProcess(
                executable: "/usr/bin/osascript",
                arguments: ["-l", "JavaScript", "-e", script],
                timeout: 2.0
            ),
               let data = out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                prevWinId = json["windowId"] as? Int
                prevTty = json["tty"] as? String
            }
        }

        return FocusSnapshot(
            previousApp: previousApp,
            previousTerminalWindowId: prevWinId,
            previousTerminalTty: prevTty
        )
    }

    private func focusTarget(_ target: AgentTarget, snapshot: FocusSnapshot) throws {
        switch target.kind {
        case .terminalTab:
            guard TargetDiscoveryService.isTerminalRunning() else {
                throw DeliveryError.targetNotFound("Terminal is not running.")
            }

            let ttyJSON = encodeJSString(target.tty ?? "")
            let winIdVal = target.windowId ?? -1
            let script = """
            const term = Application("Terminal");
            const targetTty = \(ttyJSON);
            const targetWinId = \(winIdVal);
            let found = false;
            const wins = term.windows();
            if (targetTty.length > 0) {
              for (let i = 0; i < wins.length && !found; i++) {
                const w = wins[i];
                const tabs = w.tabs();
                for (let j = 0; j < tabs.length; j++) {
                  const t = tabs[j];
                  if (t.tty() === targetTty) {
                    if (w.miniaturized()) { w.miniaturized = false; }
                    t.selected = true;
                    w.index = 1;
                    w.frontmost = true;
                    term.activate();
                    found = true;
                    break;
                  }
                }
              }
            } else if (targetWinId > 0) {
              for (let i = 0; i < wins.length; i++) {
                const w = wins[i];
                if (w.id() === targetWinId) {
                  if (w.miniaturized()) { w.miniaturized = false; }
                  w.index = 1;
                  w.frontmost = true;
                  term.activate();
                  found = true;
                  break;
                }
              }
            }
            found ? "OK" : "NOT_FOUND";
            """

            guard let out = TargetDiscoveryService.runProcess(
                executable: "/usr/bin/osascript",
                arguments: ["-l", "JavaScript", "-e", script],
                timeout: 3.0
            ) else {
                throw DeliveryError.targetNotFound("Terminal Automation permission denied or timed out.")
            }

            if out.trimmingCharacters(in: .whitespacesAndNewlines) != "OK" {
                let label = target.tty ?? target.displayName
                throw DeliveryError.targetNotFound("Terminal tab \(label) is no longer open.")
            }

            waitForAppFrontmost(bundleIdentifier: "com.apple.Terminal", maxWaitMs: 500)

        case .macApp:
            guard let bundleID = target.bundleIdentifier else {
                throw DeliveryError.targetNotFound("Missing target app identifier.")
            }
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw DeliveryError.targetNotFound("\(target.appName ?? bundleID) is no longer running.")
            }
            app.unhide()
            _ = app.activate(options: [.activateAllWindows])
            waitForAppFrontmost(bundleIdentifier: bundleID, maxWaitMs: 500)

        case .frontmostWindow:
            let selfBundle = Bundle.main.bundleIdentifier
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == selfBundle,
               let prev = snapshot.previousApp {
                _ = prev.activate()
                if let prevBundle = prev.bundleIdentifier {
                    waitForAppFrontmost(bundleIdentifier: prevBundle, maxWaitMs: 500)
                }
            }
        }
    }

    private func restoreFocus(snapshot: FocusSnapshot, switchedTerminal: Bool) {
        if switchedTerminal, let prevTty = snapshot.previousTerminalTty, TargetDiscoveryService.isTerminalRunning() {
            let ttyJSON = encodeJSString(prevTty)
            let winIdVal = snapshot.previousTerminalWindowId ?? -1
            let shouldActivateTerminal = snapshot.previousApp?.bundleIdentifier == "com.apple.Terminal"
            let script = """
            const term = Application("Terminal");
            const prevTty = \(ttyJSON);
            const prevWinId = \(winIdVal);
            const activateTerm = \(shouldActivateTerminal ? "true" : "false");
            if (term.running()) {
              const wins = term.windows();
              let restored = false;
              for (let i = 0; i < wins.length && !restored; i++) {
                const w = wins[i];
                const tabs = w.tabs();
                for (let j = 0; j < tabs.length; j++) {
                  if (tabs[j].tty() === prevTty) {
                    tabs[j].selected = true;
                    w.index = 1;
                    if (activateTerm) {
                      w.frontmost = true;
                      term.activate();
                    }
                    restored = true;
                    break;
                  }
                }
              }
              if (!restored && prevWinId > 0) {
                for (let i = 0; i < wins.length; i++) {
                  if (wins[i].id() === prevWinId) {
                    wins[i].index = 1;
                    if (activateTerm) {
                      wins[i].frontmost = true;
                      term.activate();
                    }
                    break;
                  }
                }
              }
            }
            """
            _ = TargetDiscoveryService.runProcess(
                executable: "/usr/bin/osascript",
                arguments: ["-l", "JavaScript", "-e", script],
                timeout: 2.0
            )
        }

        if let prevApp = snapshot.previousApp,
           prevApp.bundleIdentifier != "com.apple.Terminal",
           !prevApp.isTerminated {
            _ = prevApp.activate()
        }
    }

    private func waitForAppFrontmost(bundleIdentifier: String, maxWaitMs: Int) {
        let iterations = max(1, maxWaitMs / 50)
        for _ in 0..<iterations {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier {
                return
            }
            usleep(50_000)
        }
    }

    private func typeText(_ text: String, pressEnter: Bool) throws {
        guard let src = CGEventSource(stateID: .privateState) else {
            throw DeliveryError.eventSourceUnavailable
        }

        let lines = text.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            for char in line {
                var units = Array(String(char).utf16)
                guard !units.isEmpty else { continue }
                if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                   let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                    down.flags = []
                    up.flags = []
                    down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    down.post(tap: .cghidEventTap)
                    usleep(4_000)
                    up.post(tap: .cghidEventTap)
                    usleep(6_000)
                }
            }

            if lineIndex < lines.count - 1 {
                // Shift+Return preserves multiline prompts without prematurely submitting
                postKey(virtualKey: 36, flags: .maskShift, source: src)
                usleep(25_000)
            }
        }

        if pressEnter {
            usleep(150_000)
            postKey(virtualKey: 36, flags: [], source: src)
        }
    }

    private func pasteText(_ text: String, pressEnter: Bool) throws {
        guard let src = CGEventSource(stateID: .privateState) else {
            throw DeliveryError.eventSourceUnavailable
        }

        // Write-only to NSPasteboard.general to avoid triggering macOS Pasteboard read privacy prompts
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        usleep(60_000)

        // Cmd+V (virtualKey 9 = 'v' on ANSI US)
        postKey(virtualKey: 9, flags: .maskCommand, source: src)

        if pressEnter {
            usleep(220_000)
            postKey(virtualKey: 36, flags: [], source: src)
        }
    }

    private func postKey(virtualKey: CGKeyCode, flags: CGEventFlags, source: CGEventSource) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(15_000)
        up.post(tap: .cghidEventTap)
    }

    private func encodeJSString(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let arrayStr = String(data: data, encoding: .utf8),
           arrayStr.count >= 2 {
            let inner = arrayStr.dropFirst().dropLast()
            return String(inner)
        }
        return "\"\""
    }
}
