import Foundation

enum TargetKind: String, Codable {
    case terminalTab
    case macApp
    case frontmostWindow
}

struct AgentTarget: Identifiable, Hashable, Codable {
    let id: String
    let kind: TargetKind
    let displayName: String
    let subtitle: String
    let isDetectedAgent: Bool
    let tty: String?
    let windowId: Int?
    let bundleIdentifier: String?
    let appName: String?

    static let frontmostWindow = AgentTarget(
        id: "frontmost",
        kind: .frontmostWindow,
        displayName: "Current Focused Window",
        subtitle: "Types into whichever window is active when timer fires",
        isDetectedAgent: false,
        tty: nil,
        windowId: nil,
        bundleIdentifier: nil,
        appName: nil
    )
}

enum DeliveryMethod: String, Codable, CaseIterable, Identifiable {
    case typeKeys
    case pasteClipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .typeKeys: return "Type Keys"
        case .pasteClipboard: return "Paste ⌘V"
        }
    }
}

enum ScheduleMode: String, Codable, CaseIterable, Identifiable {
    case countdown
    case clockTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .countdown: return "Countdown"
        case .clockTime: return "Exact Time"
        }
    }
}

enum TimerStatus: String, Codable {
    case armed
    case paused
    case waitingForUnlock
    case sending
    case sent
    case failed
}

struct NudgeTimer: Identifiable, Codable, Equatable {
    let id: UUID
    var message: String
    var pressEnter: Bool
    var deliveryMethod: DeliveryMethod
    var target: AgentTarget
    let createdAt: Date
    var fireDate: Date
    var status: TimerStatus
    var remainingWhenPaused: TimeInterval?
    var restorePreviousFocus: Bool
    var statusNote: String?
    var completedAt: Date?

    func remainingTime(at now: Date) -> TimeInterval {
        if status == .paused, let remaining = remainingWhenPaused {
            return max(0, remaining)
        }
        return max(0, fireDate.timeIntervalSince(now))
    }
}

struct PersistedState: Codable {
    static let maxHistoryCount = 20

    var timers: [NudgeTimer]
    var history: [NudgeTimer]
    var savedPresets: [String]
    var keepAwakeEnabled: Bool
    var restoreFocusDefault: Bool
    var defaultDeliveryMethod: DeliveryMethod
    var playSoundOnSend: Bool

    static let `default` = PersistedState(
        timers: [],
        history: [],
        savedPresets: [
            "continue",
            "Continue where you left off.",
            "Please continue and finish the remaining tasks."
        ],
        keepAwakeEnabled: true,
        restoreFocusDefault: true,
        defaultDeliveryMethod: .typeKeys,
        playSoundOnSend: false
    )
}

enum TimeFormatting {
    static func countdownString(seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    static func durationWords(seconds: TimeInterval) -> String {
        let total = max(0, Int(round(seconds)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 && m > 0 {
            return "\(h)h \(m)m"
        } else if h > 0 {
            return "\(h)h"
        } else if m > 0 {
            return "\(m)m"
        } else {
            return "\(s)s"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        return df
    }()

    static func shortClockTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
