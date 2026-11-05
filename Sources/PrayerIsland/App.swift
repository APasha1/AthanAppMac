import AppKit
import EventKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private lazy var focus = FocusMonitor(settings: settings)
    private lazy var store = PrayerStore(settings: settings, focus: focus)
    private let location = LocationProvider()
    private var notch: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(to: args[i + 1], store: store, settings: settings)
            NSApp.terminate(nil)
            return
        }
        if args.contains("--list-calendars") {
            let store = EKEventStore()
            print("access:", EKEventStore.authorizationStatus(for: .event).rawValue)
            for s in store.sources { print("source:", s.title, "[\(s.sourceType.rawValue)]", "calendars:", s.calendars(for: .event).count) }
            for c in store.calendars(for: .event) { print("\(c.source.title) [\(c.source.sourceType.rawValue)] — \(c.title)") }
            if args.contains("--events") {
                let now = Date()
                let pred = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(4 * 86400), calendars: nil)
                for e in store.events(matching: pred).sorted(by: { $0.startDate < $1.startDate }) {
                    print("event: [\(e.calendar.source.title)] \(e.startDate.formatted()) \(e.title ?? "") meeting=\(FocusMonitor.looksLikeMeeting(e))")
                }
            }
            exit(0)
        }

        location.onUpdate = { [weak self] coord, name in
            guard let self, self.settings.useAutoLocation else { return }
            self.settings.latitude = coord.latitude
            self.settings.longitude = coord.longitude
            self.settings.placeName = name
        }
        if settings.useAutoLocation { location.start() }

        // Start automatically after a restart (unless turned off in Settings).
        settings.applyLoginItem()

        focus.start()
        store.start()

        notch = NotchWindowController(store: store) { [weak self] in self?.openSettings() }
        notch?.show()
        setupStatusItem()

        // First run with no location yet: open Settings so it can be set.
        if !settings.hasLocation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, !self.settings.hasLocation else { return }
                self.openSettings()
            }
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: "Prayer Island")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for slot in store.slots {
            let check = slot.prayed ? "  ✓" : ""
            let title = "\(slot.prayer.name)\t\(slot.time.formatted(date: .omitted, time: .shortened))\(check)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: slot.prayer.symbol, accessibilityDescription: nil)
            if slot.state == .current {
                item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            }
            menu.addItem(item)
        }
        if store.slots.isEmpty {
            menu.addItem(NSMenuItem(title: "Set your location to see prayer times", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        if let reason = focus.busyReason, focus.isBusy {
            menu.addItem(NSMenuItem(title: "Quiet: \(reason)", action: nil, keyEquivalent: ""))
        }
        if store.isPaused, let until = store.pausedUntil {
            menu.addItem(action("Resume Reminders (paused until \(until.formatted(date: .omitted, time: .shortened)))") { $0.store.pause(for: nil) })
        } else {
            menu.addItem(action("Pause Reminders for 1 Hour") { $0.store.pause(for: 60) })
        }
        menu.addItem(action("Preview Prayer Alert") { $0.store.testAlert() })
        let capture = action("Hide from Screenshots & Recordings") { $0.settings.hideFromCapture.toggle() }
        capture.state = settings.hideFromCapture ? .on : .off
        menu.addItem(capture)
        menu.addItem(.separator())
        menu.addItem(action("Settings…", key: ",") { $0.openSettings() })
        menu.addItem(action("Quit Prayer Island", key: "q") { _ in NSApp.terminate(nil) })
    }

    private func action(_ title: String, key: String = "", _ handler: @escaping (AppDelegate) -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key) { [weak self] in if let self { handler(self) } }
        return item
    }

    // MARK: - Settings window

    func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(location)
                .environmentObject(focus)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Prayer Island"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { handler() }
}

@main
enum PrayerIslandApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.run()
    }
}
