import Cocoa
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

final class PowerAndLockManager {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isPreventingSleep = false

    private var unlockObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    var onScreenUnlockedOrWake: (() -> Void)?

    init() {
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenUnlockedOrWake?()
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenUnlockedOrWake?()
        }
    }

    deinit {
        releaseAssertion()
        if let unlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    @discardableResult
    func updateSleepAssertion(shouldPreventSleep: Bool) -> Bool {
        if shouldPreventSleep && !isPreventingSleep {
            var newID: IOPMAssertionID = 0
            let reason = "AgentNudge waiting to send scheduled AI agent message" as CFString
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &newID
            )
            if status == kIOReturnSuccess {
                assertionID = newID
                isPreventingSleep = true
                return true
            }
            return false
        } else if !shouldPreventSleep && isPreventingSleep {
            releaseAssertion()
            return true
        }
        return true
    }

    func releaseAssertion() {
        guard isPreventingSleep else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isPreventingSleep = false
    }

    static func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool, locked {
            return true
        }
        if let lockedNum = dict["CGSSessionScreenIsLocked"] as? Int, lockedNum != 0 {
            return true
        }
        return false
    }
}
