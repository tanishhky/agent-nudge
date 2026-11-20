import Cocoa
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class ComposerState: ObservableObject {
    @Published var message: String = "continue"
    @Published var pressEnter: Bool = true
    @Published var scheduleMode: ScheduleMode = .countdown
    @Published var countdownHours: Int = 1
    @Published var countdownMinutes: Int = 0
    @Published var clockTime: Date = Date().addingTimeInterval(3600)
    @Published var isAccessibilityTrusted: Bool = DeliveryEngine.isAccessibilityTrusted()
    @Published var showHistory: Bool = false
    @Published var launchAtLoginEnabled: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()
}

struct MenuBarPopoverView: View {
    @ObservedObject var store: TimerStore
    @ObservedObject var composer: ComposerState
    @Binding var targets: [AgentTarget]
    @Binding var selectedTargetId: String
    @Binding var isRefreshingTargets: Bool

    let onRefreshTargets: () -> Void
    let onClosePopover: () -> Void

    private let quickDurationPresets: [(label: String, hours: Int, mins: Int)] = [
        ("15m", 0, 15),
        ("30m", 0, 30),
        ("1h", 1, 0),
        ("2h", 2, 0),
        ("3h", 3, 0),
        ("5h", 5, 0)
    ]

    private let trustPollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var selectedTarget: AgentTarget {
        targets.first(where: { $0.id == selectedTargetId }) ?? targets.first ?? .frontmostWindow
    }

    private var countdownTotalSeconds: TimeInterval {
        TimeInterval(composer.countdownHours * 3600 + composer.countdownMinutes * 60)
    }

    private var canArm: Bool {
        let hasMessage = !composer.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if composer.scheduleMode == .countdown {
            return hasMessage && countdownTotalSeconds > 0
        }
        return hasMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection

            if !composer.isAccessibilityTrusted {
                accessibilityBanner
            }

            composerSection

            if !store.timers.isEmpty {
                Divider()
                activeTimersSection
            }

            if !store.history.isEmpty {
                Divider()
                historySection
            }
        }
        .padding(14)
        .frame(width: 396)
        .onAppear {
            composer.isAccessibilityTrusted = DeliveryEngine.isAccessibilityTrusted()
            if #available(macOS 13.0, *) {
                composer.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
            }
            onRefreshTargets()
        }
        .onReceive(trustPollTimer) { _ in
            let trusted = DeliveryEngine.isAccessibilityTrusted()
            if trusted != composer.isAccessibilityTrusted {
                composer.isAccessibilityTrusted = trusted
            }
        }
    }

    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: store.armedCount > 0 ? "bolt.badge.clock.fill" : "bolt.badge.clock")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(store.armedCount > 0 ? Color.accentColor : Color.secondary)

            Text("AgentNudge")
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            if store.isPreventingSleep {
                HStack(spacing: 3) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 10))
                    Text("Awake")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.16))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
                .help("Mac sleep and display idle sleep are prevented while timers are armed.")
            }

            if composer.isAccessibilityTrusted {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text("Ready")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.16))
                .foregroundStyle(.green)
                .clipShape(Capsule())
            }

            settingsMenu
        }
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Keep Mac & Display Awake While Armed", isOn: $store.keepAwakeEnabled)
            Toggle("Restore Previous Window After Send", isOn: $store.restoreFocusDefault)
            Toggle("Play Sound When Sent", isOn: $store.playSoundOnSend)

            Divider()

            Picker("Delivery Method", selection: $store.defaultDeliveryMethod) {
                ForEach(DeliveryMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }

            if #available(macOS 13.0, *) {
                Toggle("Launch at Login", isOn: Binding(
                    get: { composer.launchAtLoginEnabled },
                    set: { enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            composer.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
                        } catch {
                            composer.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
                        }
                    }
                ))
            }

            Divider()

            Button("Enable Accessibility…") {
                DeliveryEngine.promptForAccessibility()
            }

            Button("Reset Accessibility Cache & Re-Prompt") {
                DeliveryEngine.resetAndPromptForAccessibility()
            }

            if store.armedCount > 0 {
                Button("Pause All Timers") {
                    store.pauseAll()
                }
            }

            Divider()

            Button("Quit AgentNudge") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility access required")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("Already enabled? Click Reset after an update or Relaunch.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 6) {
                Button("Enable") {
                    DeliveryEngine.promptForAccessibility()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Reset") {
                    DeliveryEngine.resetAndPromptForAccessibility()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Clears stale macOS permission entry after an app update and prompts fresh")

                Button("Relaunch") {
                    DeliveryEngine.relaunchApp()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Restart AgentNudge after toggling Accessibility on")

                Spacer()
            }
        }
        .padding(9)
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var composerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Target Picker
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Target Agent / App")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if selectedTarget.isDetectedAgent {
                        Text("AI Session Detected")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                }

                HStack(spacing: 6) {
                    Picker("", selection: $selectedTargetId) {
                        let aiTerminals = targets.filter { $0.kind == .terminalTab && $0.isDetectedAgent }
                        let otherTerminals = targets.filter { $0.kind == .terminalTab && !$0.isDetectedAgent }
                        let guiApps = targets.filter { $0.kind == .macApp }
                        let fallback = targets.filter { $0.kind == .frontmostWindow }

                        if !aiTerminals.isEmpty {
                            Section("Detected AI Terminal Sessions") {
                                ForEach(aiTerminals) { target in
                                    Text("⚡ \(target.displayName)  —  \(target.subtitle)")
                                        .tag(target.id)
                                }
                            }
                        }

                        if !otherTerminals.isEmpty {
                            Section("Other Terminal Tabs") {
                                ForEach(otherTerminals) { target in
                                    Text("\(target.displayName) (\(target.subtitle))")
                                        .tag(target.id)
                                }
                            }
                        }

                        if !guiApps.isEmpty {
                            Section("Running Apps") {
                                ForEach(guiApps) { target in
                                    Text(target.isDetectedAgent ? "✦ \(target.displayName)" : target.displayName)
                                        .tag(target.id)
                                }
                            }
                        }

                        if !fallback.isEmpty {
                            Section("Fallback") {
                                ForEach(fallback) { target in
                                    Text(target.displayName).tag(target.id)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Button(action: onRefreshTargets) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .medium))
                            .rotationEffect(.degrees(isRefreshingTargets ? 360 : 0))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Refresh Terminal tabs and running apps")
                }
            }

            // Message Input + Presets
            VStack(alignment: .leading, spacing: 5) {
                TextField("Message to type (e.g. continue)", text: $composer.message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .font(.system(size: 12.5))

                HStack(spacing: 5) {
                    ForEach(store.savedPresets, id: \.self) { preset in
                        Button {
                            composer.message = preset
                        } label: {
                            Text(presetLabel(preset))
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(composer.message == preset ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Toggle("Return ⏎", isOn: $composer.pressEnter)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
            }

            // Schedule Picker
            VStack(alignment: .leading, spacing: 7) {
                Picker("", selection: $composer.scheduleMode) {
                    ForEach(ScheduleMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if composer.scheduleMode == .countdown {
                    countdownControls
                } else {
                    clockTimeControls
                }
            }

            // Action Buttons
            HStack(spacing: 8) {
                Button {
                    armFromComposer()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "timer")
                        Text("Arm Timer")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canArm)
                .keyboardShortcut(.return, modifiers: .command)

                Button {
                    testIn3Seconds()
                } label: {
                    Text("Test in 3s")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(composer.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Schedules this message to fire in 3 seconds and closes the popover.")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var countdownControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(quickDurationPresets, id: \.label) { preset in
                    let isSelected = composer.countdownHours == preset.hours && composer.countdownMinutes == preset.mins
                    Button {
                        composer.countdownHours = preset.hours
                        composer.countdownMinutes = preset.mins
                    } label: {
                        Text(preset.label)
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    TextField("0", value: $composer.countdownHours, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 40)
                        .multilineTextAlignment(.center)
                        .onChange(of: composer.countdownHours) { _, newVal in
                            composer.countdownHours = min(23, max(0, newVal))
                        }
                    Stepper("", value: $composer.countdownHours, in: 0...23)
                        .labelsHidden()
                    Text("hr")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    TextField("0", value: $composer.countdownMinutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 40)
                        .multilineTextAlignment(.center)
                        .onChange(of: composer.countdownMinutes) { _, newVal in
                            composer.countdownMinutes = min(59, max(0, newVal))
                        }
                    Stepper("", value: $composer.countdownMinutes, in: 0...59)
                        .labelsHidden()
                    Text("min")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if countdownTotalSeconds > 0 {
                    let eta = store.now.addingTimeInterval(countdownTotalSeconds)
                    Text("At \(TimeFormatting.shortClockTime(eta))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var clockTimeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                DatePicker("", selection: $composer.clockTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)

                Button("Next Hr") {
                    let cal = Calendar.current
                    if let nextHour = cal.date(byAdding: .hour, value: 1, to: Date()) {
                        var comps = cal.dateComponents([.year, .month, .day, .hour], from: nextHour)
                        comps.minute = 0
                        composer.clockTime = cal.date(from: comps) ?? nextHour
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("+2h") {
                    composer.clockTime = Date().addingTimeInterval(2 * 3600)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("+5h") {
                    composer.clockTime = Date().addingTimeInterval(5 * 3600)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            let resolved = TimerStore.resolveNextClockOccurrence(for: composer.clockTime, relativeTo: store.now)
            let isTomorrow = !Calendar.current.isDate(resolved, inSameDayAs: store.now)
            let diff = max(0, resolved.timeIntervalSince(store.now))
            Text("\(isTomorrow ? "Tomorrow" : "Today") at \(TimeFormatting.shortClockTime(resolved)) (in \(TimeFormatting.durationWords(seconds: diff)))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var activeTimersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Active Timers (\(store.timers.count))")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.armedCount > 1 {
                    Button("Pause All") {
                        store.pauseAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.timers) { timer in
                        activeTimerRow(timer)
                    }
                }
            }
            .frame(maxHeight: 165)
        }
    }

    private func activeTimerRow(_ timer: NudgeTimer) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(timer.target.displayName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)

                    if timer.status == .paused {
                        Text("PAUSED")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else if timer.status == .waitingForUnlock {
                        Text("LOCKED")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else if timer.status == .sending {
                        Text("SENDING")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                Text("“\(timer.message)”")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(TimeFormatting.countdownString(seconds: timer.remainingTime(at: store.now)))
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(timer.status == .paused ? .secondary : .primary)

                Text(TimeFormatting.shortClockTime(timer.fireDate))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 3) {
                Button {
                    store.sendNow(id: timer.id)
                } label: {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Send immediately")
                .disabled(timer.status == .sending)

                Button {
                    store.togglePause(id: timer.id)
                } label: {
                    Image(systemName: timer.status == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help(timer.status == .paused ? "Resume timer" : "Pause timer")
                .disabled(timer.status == .sending)

                Button {
                    store.addMinutes(id: timer.id, minutes: 5)
                } label: {
                    Text("+5m")
                        .font(.system(size: 9.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Add 5 minutes")
                .disabled(timer.status == .sending)

                Button {
                    store.cancel(id: timer.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Cancel timer")
                .disabled(timer.status == .sending)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var historySection: some View {
        DisclosureGroup(isExpanded: $composer.showHistory) {
            VStack(spacing: 5) {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(store.history.prefix(10)) { item in
                            HStack(spacing: 6) {
                                Image(systemName: item.status == .sent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(item.status == .sent ? .green : .orange)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(item.target.displayName): “\(item.message)”")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .lineLimit(1)
                                    if let note = item.statusNote {
                                        Text(note)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }

                                Spacer()

                                Button("Retry") {
                                    store.retryFromHistoryNow(item)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                            .padding(6)
                            .background(Color.primary.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .frame(maxHeight: 115)

                HStack {
                    Spacer()
                    Button("Clear History") {
                        store.clearHistory()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Recent History (\(store.history.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func presetLabel(_ preset: String) -> String {
        if preset == "continue" { return "continue" }
        if preset.count > 16 {
            let idx = preset.index(preset.startIndex, offsetBy: 16)
            return String(preset[..<idx]) + "…"
        }
        return preset
    }

    private func armFromComposer() {
        if composer.scheduleMode == .countdown {
            store.armCountdown(
                message: composer.message,
                target: selectedTarget,
                durationSeconds: countdownTotalSeconds,
                pressEnter: composer.pressEnter,
                deliveryMethod: store.defaultDeliveryMethod,
                restoreFocus: store.restoreFocusDefault
            )
        } else {
            store.armClockTime(
                message: composer.message,
                target: selectedTarget,
                clockDate: composer.clockTime,
                pressEnter: composer.pressEnter,
                deliveryMethod: store.defaultDeliveryMethod,
                restoreFocus: store.restoreFocusDefault
            )
        }
    }

    private func testIn3Seconds() {
        store.armCountdown(
            message: composer.message,
            target: selectedTarget,
            durationSeconds: 3,
            pressEnter: composer.pressEnter,
            deliveryMethod: store.defaultDeliveryMethod,
            restoreFocus: store.restoreFocusDefault
        )
        onClosePopover()
    }
}
