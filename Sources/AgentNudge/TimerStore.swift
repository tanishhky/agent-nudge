import Cocoa
import Combine
import Foundation

@MainActor
final class TimerStore: ObservableObject {
    @Published private(set) var timers: [NudgeTimer] = []
    @Published private(set) var history: [NudgeTimer] = []
    @Published var savedPresets: [String] = PersistedState.default.savedPresets
    @Published var keepAwakeEnabled: Bool = true {
        didSet {
            refreshSleepAssertion()
            persist()
        }
    }
    @Published var restoreFocusDefault: Bool = true {
        didSet { persist() }
    }
    @Published var defaultDeliveryMethod: DeliveryMethod = .typeKeys {
        didSet { persist() }
    }
    @Published var playSoundOnSend: Bool = false {
        didSet { persist() }
    }
    @Published private(set) var now: Date = Date()
    @Published private(set) var isPreventingSleep: Bool = false

    let powerManager = PowerAndLockManager()
    private let stateURL: URL
    private var tickTimer: Timer?
    private var isDeliveringBatch = false
    private var isLoading = false

    var onClosePopoverRequested: (() -> Void)?
    var externalFrontmostAppProvider: (() -> NSRunningApplication?)?
    var onStatusBarUpdate: (() -> Void)?

    init(stateURL: URL? = nil, startTickLoop: Bool = true) {
        if let stateURL {
            self.stateURL = stateURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("AgentNudge", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.stateURL = dir.appendingPathComponent("state.json")
        }

        load()
        powerManager.onScreenUnlockedOrWake = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleWakeOrUnlock()
            }
        }
        refreshSleepAssertion()

        if startTickLoop {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        }
    }

    deinit {
        tickTimer?.invalidate()
        powerManager.releaseAssertion()
    }

    var armedCount: Int {
        timers.filter { $0.status == .armed || $0.status == .waitingForUnlock || $0.status == .sending }.count
    }

    var menuBarLabel: String {
        let nowDate = now
        if let soonestArmed = timers
            .filter({ $0.status == .armed })
            .sorted(by: { $0.fireDate < $1.fireDate })
            .first {
            let remaining = soonestArmed.remainingTime(at: nowDate)
            let formatted = TimeFormatting.countdownString(seconds: remaining)
            let extraCount = armedCount - 1
            if extraCount > 0 {
                return " \(formatted) (+\(extraCount))"
            }
            return " \(formatted)"
        }

        if timers.contains(where: { $0.status == .waitingForUnlock }) {
            return " 🔒 Queued"
        }

        if timers.contains(where: { $0.status == .sending }) {
            return " Sending…"
        }

        return ""
    }

    func armCountdown(
        message: String,
        target: AgentTarget,
        durationSeconds: TimeInterval,
        pressEnter: Bool,
        deliveryMethod: DeliveryMethod,
        restoreFocus: Bool
    ) {
        let clamped = max(1, durationSeconds)
        let fireDate = Date().addingTimeInterval(clamped)
        addTimer(
            message: message,
            target: target,
            fireDate: fireDate,
            pressEnter: pressEnter,
            deliveryMethod: deliveryMethod,
            restoreFocus: restoreFocus
        )
    }

    func armClockTime(
        message: String,
        target: AgentTarget,
        clockDate: Date,
        pressEnter: Bool,
        deliveryMethod: DeliveryMethod,
        restoreFocus: Bool
    ) {
        let resolved = Self.resolveNextClockOccurrence(for: clockDate, relativeTo: Date())
        addTimer(
            message: message,
            target: target,
            fireDate: resolved,
            pressEnter: pressEnter,
            deliveryMethod: deliveryMethod,
            restoreFocus: restoreFocus
        )
    }

    static func resolveNextClockOccurrence(for clockDate: Date, relativeTo reference: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: clockDate)
        var targetComps = cal.dateComponents([.year, .month, .day], from: reference)
        targetComps.hour = comps.hour
        targetComps.minute = comps.minute
        targetComps.second = 0

        let candidate = cal.date(from: targetComps) ?? reference.addingTimeInterval(60)
        if candidate <= reference {
            return cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate.addingTimeInterval(86400)
        }
        return candidate
    }

    private func addTimer(
        message: String,
        target: AgentTarget,
        fireDate: Date,
        pressEnter: Bool,
        deliveryMethod: DeliveryMethod,
        restoreFocus: Bool
    ) {
        let trimmed = message.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }

        let timer = NudgeTimer(
            id: UUID(),
            message: trimmed,
            pressEnter: pressEnter,
            deliveryMethod: deliveryMethod,
            target: target,
            createdAt: Date(),
            fireDate: fireDate,
            status: .armed,
            remainingWhenPaused: nil,
            restorePreviousFocus: restoreFocus,
            statusNote: nil,
            completedAt: nil
        )
        timers.append(timer)
        timers.sort { $0.fireDate < $1.fireDate }
        refreshSleepAssertion()
        persist()
        onStatusBarUpdate?()
    }

    func togglePause(id: UUID) {
        guard let idx = timers.firstIndex(where: { $0.id == id }) else { return }
        let currentNow = Date()
        if timers[idx].status == .armed {
            let rem = max(1, timers[idx].fireDate.timeIntervalSince(currentNow))
            timers[idx].remainingWhenPaused = rem
            timers[idx].status = .paused
            timers[idx].statusNote = "Paused"
        } else if timers[idx].status == .paused {
            let rem = max(1, timers[idx].remainingWhenPaused ?? 60)
            timers[idx].fireDate = currentNow.addingTimeInterval(rem)
            timers[idx].remainingWhenPaused = nil
            timers[idx].status = .armed
            timers[idx].statusNote = nil
        } else if timers[idx].status == .waitingForUnlock {
            timers[idx].status = .paused
            timers[idx].remainingWhenPaused = 5
            timers[idx].statusNote = "Paused"
        }
        refreshSleepAssertion()
        persist()
        onStatusBarUpdate?()
    }

    func pauseAll() {
        let currentNow = Date()
        for idx in timers.indices where timers[idx].status == .armed || timers[idx].status == .waitingForUnlock {
            let rem = max(1, timers[idx].fireDate.timeIntervalSince(currentNow))
            timers[idx].remainingWhenPaused = rem
            timers[idx].status = .paused
            timers[idx].statusNote = "Paused"
        }
        refreshSleepAssertion()
        persist()
        onStatusBarUpdate?()
    }

    func addMinutes(id: UUID, minutes: Int) {
        guard let idx = timers.firstIndex(where: { $0.id == id }) else { return }
        let delta = TimeInterval(minutes * 60)
        if timers[idx].status == .paused {
            timers[idx].remainingWhenPaused = max(1, (timers[idx].remainingWhenPaused ?? 0) + delta)
        } else {
            timers[idx].fireDate = timers[idx].fireDate.addingTimeInterval(delta)
        }
        timers.sort { $0.fireDate < $1.fireDate }
        persist()
        onStatusBarUpdate?()
    }

    func cancel(id: UUID) {
        timers.removeAll { $0.id == id }
        refreshSleepAssertion()
        persist()
        onStatusBarUpdate?()
    }

    func sendNow(id: UUID) {
        guard let idx = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[idx].fireDate = Date()
        timers[idx].remainingWhenPaused = nil
        timers[idx].status = .armed
        timers[idx].statusNote = nil
        tick()
    }

    func rearmFromHistory(_ item: NudgeTimer, inMinutes: Int) {
        armCountdown(
            message: item.message,
            target: item.target,
            durationSeconds: TimeInterval(max(1, inMinutes) * 60),
            pressEnter: item.pressEnter,
            deliveryMethod: item.deliveryMethod,
            restoreFocus: item.restorePreviousFocus
        )
    }

    func retryFromHistoryNow(_ item: NudgeTimer) {
        armCountdown(
            message: item.message,
            target: item.target,
            durationSeconds: 0.2,
            pressEnter: item.pressEnter,
            deliveryMethod: item.deliveryMethod,
            restoreFocus: item.restorePreviousFocus
        )
        tick()
    }

    func clearHistory() {
        history.removeAll()
        persist()
    }

    func shutdown() {
        tickTimer?.invalidate()
        tickTimer = nil
        powerManager.releaseAssertion()
        isPreventingSleep = false
        persist()
    }

    private func handleWakeOrUnlock() {
        now = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.tick()
        }
    }

    func tick() {
        now = Date()
        onStatusBarUpdate?()

        guard !isDeliveringBatch else { return }

        let locked = PowerAndLockManager.isScreenLocked()
        var dueIDs: [UUID] = []

        for idx in timers.indices {
            switch timers[idx].status {
            case .armed:
                if now >= timers[idx].fireDate {
                    if locked {
                        timers[idx].status = .waitingForUnlock
                        timers[idx].statusNote = "Screen locked — will send on unlock"
                    } else {
                        dueIDs.append(timers[idx].id)
                    }
                }
            case .waitingForUnlock:
                if !locked {
                    dueIDs.append(timers[idx].id)
                }
            default:
                break
            }
        }

        if locked {
            persist()
            onStatusBarUpdate?()
        }

        guard !dueIDs.isEmpty else { return }

        var batch: [NudgeTimer] = []
        for idx in timers.indices where dueIDs.contains(timers[idx].id) {
            timers[idx].status = .sending
            timers[idx].statusNote = "Sending…"
            batch.append(timers[idx])
        }

        isDeliveringBatch = true
        onStatusBarUpdate?()

        let fallbackApp = externalFrontmostAppProvider?()
        let closePopover = onClosePopoverRequested ?? {}

        Task { [weak self] in
            let results = await DeliveryEngine.shared.deliverBatch(
                batch,
                fallbackExternalApp: fallbackApp,
                closePopoverHandler: closePopover
            )
            await MainActor.run { [weak self] in
                self?.finishBatch(results: results)
            }
        }
    }

    private func finishBatch(results: [UUID: Result<String, Error>]) {
        isDeliveringBatch = false
        let completionTime = Date()
        var anySucceeded = false

        for (id, result) in results {
            guard let idx = timers.firstIndex(where: { $0.id == id }) else { continue }
            var completed = timers.remove(at: idx)
            completed.completedAt = completionTime
            switch result {
            case .success(let note):
                completed.status = .sent
                completed.statusNote = note
                anySucceeded = true
            case .failure(let error):
                completed.status = .failed
                completed.statusNote = error.localizedDescription
            }
            history.insert(completed, at: 0)
        }

        if history.count > PersistedState.maxHistoryCount {
            history = Array(history.prefix(PersistedState.maxHistoryCount))
        }

        if anySucceeded && playSoundOnSend {
            NSSound(named: "Tink")?.play()
        }

        refreshSleepAssertion()
        persist()
        onStatusBarUpdate?()
    }

    func refreshSleepAssertion() {
        guard !isLoading else { return }
        let needsSleepPrevention = keepAwakeEnabled && timers.contains {
            $0.status == .armed || $0.status == .waitingForUnlock || $0.status == .sending
        }
        _ = powerManager.updateSleepAssertion(shouldPreventSleep: needsSleepPrevention)
        isPreventingSleep = powerManager.isPreventingSleep
    }

    func persist() {
        guard !isLoading else { return }
        let state = PersistedState(
            timers: timers,
            history: history,
            savedPresets: savedPresets,
            keepAwakeEnabled: keepAwakeEnabled,
            restoreFocusDefault: restoreFocusDefault,
            defaultDeliveryMethod: defaultDeliveryMethod,
            playSoundOnSend: playSoundOnSend
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode(PersistedState.self, from: data) else { return }

        isLoading = true
        var migratedMissed = false

        savedPresets = loaded.savedPresets.isEmpty ? PersistedState.default.savedPresets : loaded.savedPresets
        keepAwakeEnabled = loaded.keepAwakeEnabled
        restoreFocusDefault = loaded.restoreFocusDefault
        defaultDeliveryMethod = loaded.defaultDeliveryMethod
        playSoundOnSend = loaded.playSoundOnSend

        let currentNow = Date()
        var active: [NudgeTimer] = []
        var past = loaded.history

        for var item in loaded.timers {
            if item.status == .sending {
                item.status = .armed
                migratedMissed = true
            }
            if (item.status == .armed || item.status == .waitingForUnlock),
               currentNow.timeIntervalSince(item.fireDate) > 120 {
                item.status = .failed
                item.statusNote = "Missed while AgentNudge was closed"
                item.completedAt = currentNow
                past.insert(item, at: 0)
                migratedMissed = true
            } else {
                active.append(item)
            }
        }

        timers = active.sorted { $0.fireDate < $1.fireDate }
        history = Array(past.prefix(PersistedState.maxHistoryCount))
        isLoading = false

        if migratedMissed {
            persist()
        }
    }
}
