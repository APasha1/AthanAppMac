import AppKit
import Combine
import SwiftUI

/// Notch dimensions for the screen the island lives on.
struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool

    static func of(_ screen: NSScreen) -> NotchMetrics {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            let w = screen.frame.width - left.width - right.width
            return NotchMetrics(width: w, height: screen.safeAreaInsets.top, hasNotch: true)
        }
        // No notch (external display / clamshell): a floating pill just under the top edge.
        return NotchMetrics(width: 180, height: max(24, NSStatusBar.system.thickness), hasNotch: false)
    }
}

/// Shared UI state between the window controller and SwiftUI.
@MainActor
final class IslandState: ObservableObject {
    @Published var metrics = NotchMetrics(width: 200, height: 32, hasNotch: true)
    @Published var hovering = false
    /// An app is full screen on the island's display.
    @Published var fullScreen = false

    static let canvas = CGSize(width: 560, height: 280)

    enum Layout { case hidden, compact, peek, expanded, alert }

    func layout(for store: PrayerStore) -> Layout {
        if store.isOnCall { return .hidden }
        // In full screen, stay out of sight except for prayer time and "time is running out".
        if fullScreen {
            switch store.mode {
            case .alert: return .alert
            case .peek(let p) where p.canMarkPrayed || p.important: return .peek
            default: return .hidden
            }
        }
        switch store.mode {
        case .alert: return .alert
        case .peek: return hovering ? .expanded : .peek
        case .compact: return hovering ? .expanded : .compact
        }
    }

    func size(for layout: Layout, showWings: Bool) -> CGSize {
        let n = metrics
        switch layout {
        case .hidden: return CGSize(width: n.width, height: n.height)
        case .compact: return CGSize(width: n.width + (showWings ? 2 * 78 : 0), height: n.height)
        case .peek: return CGSize(width: max(n.width + 220, 420), height: n.height + 58)
        case .expanded: return CGSize(width: 480, height: n.height + 196)
        case .alert: return CGSize(width: 480, height: n.height + 128)
        }
    }
}

/// A borderless panel that sits over the notch, never steals focus, and is excluded from screen capture.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        sharingType = .none
    }

    /// Leave the island out of screenshots, recordings and screen shares, or let them see it.
    /// (PRAYER_ISLAND_CAPTURABLE=1 forces it visible, for taking screenshots of the app itself.)
    func setHiddenFromCapture(_ hidden: Bool) {
        let forced = ProcessInfo.processInfo.environment["PRAYER_ISLAND_CAPTURABLE"] == "1"
        sharingType = hidden && !forced ? .none : .readOnly
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchWindowController {
    private let panel = NotchPanel()
    private let store: PrayerStore
    private let state = IslandState()
    private var mouseTimer: Timer?
    private var hoverTask: Task<Void, Never>?
    private var pendingHover: Bool?
    private var pointerInside = false
    private var fullScreenTimer: Timer?
    private var bag = Set<AnyCancellable>()

    init(store: PrayerStore, openSettings: @escaping () -> Void) {
        self.store = store
        let root = IslandView(openSettings: openSettings)
            .environmentObject(store)
            .environmentObject(store.settings)
            .environmentObject(state)
        let host = ClickThroughHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host

        store.isPointerOnIsland = { [weak self] in self?.pointerInside ?? false }

        reposition()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }

        store.settings.$hideFromCapture
            .sink { [weak self] in self?.panel.setHiddenFromCapture($0) }
            .store(in: &bag)

        // Fade out completely while busy, so nothing shows even if a capture tool ignores sharingType.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateVisibility() }
            .store(in: &bag)
    }

    func show() {
        panel.orderFrontRegardless()
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackMouse() }
        }
        RunLoop.main.add(mouseTimer!, forMode: .common)

        checkFullScreen()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkFullScreen() }
        }
        // Space changes cover most cases; a slow poll catches the rest.
        fullScreenTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkFullScreen() }
        }
    }

    private func checkFullScreen() {
        let fs = FullScreenDetector.isFullScreen(screen)
        if fs != state.fullScreen {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                state.fullScreen = fs
                if fs { state.hovering = false }
            }
        }
    }

    private var screen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func reposition() {
        let s = screen
        state.metrics = NotchMetrics.of(s)
        let size = IslandState.canvas
        let origin = NSPoint(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func updateVisibility() {
        let hidden = store.isOnCall
        let target: CGFloat = hidden ? 0 : 1
        guard panel.alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = hidden ? 0.15 : 0.5
            panel.animator().alphaValue = target
        }
    }

    /// Hover detection by polling, so the transparent parts of the panel never block clicks.
    private func trackMouse() {
        let layout = state.layout(for: store)
        if layout == .hidden {
            panel.ignoresMouseEvents = true
            if state.hovering { state.hovering = false }
            return
        }
        let size = state.size(for: layout, showWings: store.settings.showWings)
        let frame = panel.frame
        var rect = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
        // A little slack so it doesn't flicker at the edges; reach to the very top edge of the screen.
        rect = rect.insetBy(dx: -6, dy: -6)
        let inside = rect.contains(NSEvent.mouseLocation)
        pointerInside = inside
        panel.ignoresMouseEvents = !inside

        // In click mode, entering never opens it (a click does); leaving still closes it.
        if !store.settings.openOnHover && inside && !state.hovering { return }

        if inside != state.hovering {
            guard pendingHover != inside else { return }
            hoverTask?.cancel()
            pendingHover = inside
            let delay: Duration = inside ? .milliseconds(120) : .milliseconds(350)
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.pendingHover = nil
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { self.state.hovering = inside }
            }
        } else if pendingHover != nil {
            hoverTask?.cancel()
            pendingHover = nil
        }
    }
}

/// Lets the first click on the (never-key) panel go straight to SwiftUI.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Asks the window server what kind of Space is showing on a display (4 = a full-screen app).
enum FullScreenDetector {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let fns: (ConnectionFn, SpacesFn)? = {
        guard let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let conn = dlsym(sl, "SLSMainConnectionID"),
              let spaces = dlsym(sl, "SLSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(conn, to: ConnectionFn.self), unsafeBitCast(spaces, to: SpacesFn.self))
    }()

    static func isFullScreen(_ screen: NSScreen) -> Bool {
        guard let (conn, spaces) = fns,
              let displays = spaces(conn())?.takeRetainedValue() as? [[String: Any]] else { return false }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        let uuid = CFUUIDCreateString(nil, CGDisplayCreateUUIDFromDisplayID(id).takeRetainedValue()) as String?
        // With "Displays have separate Spaces" off there is a single entry for every display.
        let display = displays.first { ($0["Display Identifier"] as? String) == uuid } ?? (displays.count == 1 ? displays[0] : nil)
        let current = display?["Current Space"] as? [String: Any]
        return (current?["type"] as? Int) == 4
    }
}
