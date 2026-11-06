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
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(to: args[i + 1], store: store, settings: settings)
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--snapshot-onboarding"), i + 1 < args.count {
            snapshotOnboarding(to: args[i + 1])
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
        if settings.useAutoLocation && settings.onboarded { location.start() }

        // Start automatically after a restart (unless turned off in Settings).
        settings.applyLoginItem()

        focus.start()
        store.start()

        notch = NotchWindowController(store: store) { [weak self] in self?.openSettings() }
        notch?.show()
        setupStatusItem()

        // First run (or --onboarding): walk through permissions and location.
        if !settings.onboarded || args.contains("--onboarding") {
            openOnboarding()
        } else if !settings.hasLocation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, !self.settings.hasLocation else { return }
                self.openSettings()
            }
        }
    }

    // MARK: - Onboarding

    private func onboardingView(step: OnboardingView.Step = .welcome) -> some View {
        OnboardingView(step: step) { [weak self] in
            guard let self else { return }
            self.settings.onboarded = true
            self.focus.requestCalendar()
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            self.store.testPeek()
        }
        .environmentObject(settings)
        .environmentObject(store)
        .environmentObject(location)
        .environmentObject(focus)
    }

    private func openOnboarding() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: onboardingView()))
        window.title = "Welcome to Athan App Mac"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// `--snapshot-onboarding <dir>`: renders each onboarding step to a PNG (for the README).
    func snapshotOnboarding(to dir: String) {
        if !settings.hasLocation {
            settings.latitude = 40.7128; settings.longitude = -74.0060; settings.placeName = "New York, NY"
        }
        store.start()
        for step in OnboardingView.Step.allCases {
            let host = NSHostingView(rootView: onboardingView(step: step))
            let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 520, height: 580),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = rep.representation(using: .png, properties: [:])
            try? png?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("onboarding-\(step.rawValue + 1)-\(step).png"))
            window.orderOut(nil)
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: "Athan App Mac")
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
        menu.addItem(action("Quit Athan App Mac", key: "q") { _ in NSApp.terminate(nil) })
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
            window.title = "Athan App Mac"
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
enum AthanAppMacApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.run()
    }
}
