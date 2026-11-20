import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = TimerStore()
    private let composer = ComposerState()

    @Published private var targets: [AgentTarget] = [.frontmostWindow]
    @Published private var selectedTargetId: String = AgentTarget.frontmostWindow.id
    @Published private var isRefreshingTargets: Bool = false

    private var lastExternalFrontmostApp: NSRunningApplication?
    private var appActivateObserver: NSObjectProtocol?
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenuWithEditActions()

        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalFrontmostApp = front
        }

        appActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor [weak self] in
                if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self?.lastExternalFrontmostApp = app
                }
            }
        }

        store.externalFrontmostAppProvider = { [weak self] in
            self?.lastExternalFrontmostApp
        }
        store.onClosePopoverRequested = { [weak self] in
            self?.closePopover()
        }
        store.onStatusBarUpdate = { [weak self] in
            self?.updateStatusItemAppearance()
        }

        setupStatusItem()
        setupPopover()
        refreshTargets()
        updateStatusItemAppearance()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let appActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivateObserver)
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        store.shutdown()
    }

    private func setupMainMenuWithEditActions() {
        // Required so Cmd+C / Cmd+V / Cmd+X / Cmd+A / Cmd+Z work inside NSPopover text fields in an LSUIElement app
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        editMenuItem.title = "Edit"
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        let contentView = PopoverRootContainer(
            store: store,
            composer: composer,
            appDelegate: self,
            onRefreshTargets: { [weak self] in self?.refreshTargets() },
            onClosePopover: { [weak self] in self?.closePopover() }
        )

        let hostingController = NSHostingController(rootView: contentView)
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 396, height: 500)
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let symbolName = store.armedCount > 0 ? "bolt.badge.clock.fill" : "bolt.badge.clock"
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AgentNudge") {
            img.isTemplate = true
            button.image = img
        }
        button.title = store.menuBarLabel
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        refreshTargets()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        if eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if self?.popover.isShown == true {
                        self?.closePopover()
                    }
                }
            }
        }
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let keepAwakeItem = NSMenuItem(
            title: "Keep Mac & Display Awake",
            action: #selector(toggleKeepAwakeAction),
            keyEquivalent: ""
        )
        keepAwakeItem.state = store.keepAwakeEnabled ? .on : .off
        keepAwakeItem.target = self
        menu.addItem(keepAwakeItem)

        if store.armedCount > 0 {
            let pauseAllItem = NSMenuItem(
                title: "Pause All Timers",
                action: #selector(pauseAllAction),
                keyEquivalent: ""
            )
            pauseAllItem.target = self
            menu.addItem(pauseAllItem)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit AgentNudge",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleKeepAwakeAction() {
        store.keepAwakeEnabled.toggle()
    }

    @objc private func pauseAllAction() {
        store.pauseAll()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    func refreshTargets() {
        guard !isRefreshingTargets else { return }
        isRefreshingTargets = true
        TargetDiscoveryService.discoverTargets { [weak self] discovered in
            guard let self else { return }
            self.targets = discovered
            self.isRefreshingTargets = false

            let stillExists = discovered.contains(where: { $0.id == self.selectedTargetId })
            if !stillExists || self.selectedTargetId == AgentTarget.frontmostWindow.id {
                if let firstAgent = discovered.first(where: { $0.isDetectedAgent }) {
                    self.selectedTargetId = firstAgent.id
                } else if let firstTerminal = discovered.first(where: { $0.kind == .terminalTab }) {
                    self.selectedTargetId = firstTerminal.id
                } else if !stillExists {
                    self.selectedTargetId = discovered.first?.id ?? AgentTarget.frontmostWindow.id
                }
            }
        }
    }

    fileprivate var targetsBinding: Binding<[AgentTarget]> {
        Binding(get: { self.targets }, set: { self.targets = $0 })
    }

    fileprivate var selectedTargetBinding: Binding<String> {
        Binding(get: { self.selectedTargetId }, set: { self.selectedTargetId = $0 })
    }

    fileprivate var refreshingBinding: Binding<Bool> {
        Binding(get: { self.isRefreshingTargets }, set: { self.isRefreshingTargets = $0 })
    }
}

private struct PopoverRootContainer: View {
    @ObservedObject var store: TimerStore
    @ObservedObject var composer: ComposerState
    @ObservedObject var appDelegate: AppDelegate
    let onRefreshTargets: () -> Void
    let onClosePopover: () -> Void

    var body: some View {
        MenuBarPopoverView(
            store: store,
            composer: composer,
            targets: appDelegate.targetsBinding,
            selectedTargetId: appDelegate.selectedTargetBinding,
            isRefreshingTargets: appDelegate.refreshingBinding,
            onRefreshTargets: onRefreshTargets,
            onClosePopover: onClosePopover
        )
    }
}
