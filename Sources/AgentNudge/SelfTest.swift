import Foundation

enum SelfTest {
    @MainActor
    static func run() -> Int32 {
        print("Running AgentNudge self-test...")

        // 1. Target discovery check
        let targets = TargetDiscoveryService.discoverTargetsSync()
        guard !targets.isEmpty else {
            fputs("FAIL: No targets discovered.\n", stderr)
            return 1
        }
        let terminalTabs = targets.filter { $0.kind == .terminalTab }
        let aiTabs = terminalTabs.filter { $0.isDetectedAgent }
        let guiApps = targets.filter { $0.kind == .macApp }
        print("PASS: Discovered \(targets.count) targets (\(terminalTabs.count) Terminal tabs, \(aiTabs.count) detected AI CLI sessions, \(guiApps.count) GUI apps).")
        for tab in aiTabs {
            print("  - AI Session: \(tab.displayName) | \(tab.subtitle)")
        }

        // 2. Power & lock manager check
        let power = PowerAndLockManager()
        let acquired = power.updateSleepAssertion(shouldPreventSleep: true)
        guard acquired, power.isPreventingSleep else {
            fputs("FAIL: Failed to acquire IOPMAssertion PreventUserIdleDisplaySleep.\n", stderr)
            return 1
        }
        power.releaseAssertion()
        guard !power.isPreventingSleep else {
            fputs("FAIL: Failed to release IOPMAssertion.\n", stderr)
            return 1
        }
        let locked = PowerAndLockManager.isScreenLocked()
        print("PASS: IOPMAssertion acquire/release succeeded. Screen locked = \(locked).")

        // 3. TimerStore scheduling + persistence round-trip in isolated temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-nudge-selftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = TimerStore(stateURL: tempURL, startTickLoop: false)
        let target = aiTabs.first ?? targets.first ?? .frontmostWindow
        store.armCountdown(
            message: "continue",
            target: target,
            durationSeconds: 3600,
            pressEnter: true,
            deliveryMethod: .typeKeys,
            restoreFocus: true
        )

        let twoHoursAhead = Date().addingTimeInterval(7200)
        store.armClockTime(
            message: "Finish tests",
            target: .frontmostWindow,
            clockDate: twoHoursAhead,
            pressEnter: true,
            deliveryMethod: .pasteClipboard,
            restoreFocus: true
        )

        guard store.timers.count == 2, store.armedCount == 2 else {
            fputs("FAIL: Expected 2 armed timers, got \(store.timers.count).\n", stderr)
            return 1
        }
        let label = store.menuBarLabel
        guard label.contains("(+1)") else {
            fputs("FAIL: Expected menuBarLabel to include '(+1)', got '\(label)'.\n", stderr)
            return 1
        }

        // Verify JSON reload into a second TimerStore instance
        let reloaded = TimerStore(stateURL: tempURL, startTickLoop: false)
        guard reloaded.timers.count == 2 else {
            fputs("FAIL: Expected 2 reloaded timers from JSON, got \(reloaded.timers.count).\n", stderr)
            return 1
        }

        reloaded.shutdown()
        store.shutdown()

        print("PASS: TimerStore countdown + clock-time + JSON persistence verified (menuBarLabel = '\(label)').")
        print("Accessibility trusted = \(DeliveryEngine.isAccessibilityTrusted())")
        print("SELF_TEST_PASSED")
        return 0
    }
}
