import CoreAudio
import CoreMediaIO
import EventKit
import Foundation

struct MeetingEvent: Equatable {
    let title: String
    let start: Date
    let end: Date
}

/// Works out whether you're in a meeting: a calendar meeting now, or the mic/camera in use by any app.
@MainActor
final class FocusMonitor: ObservableObject {
    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false
    @Published private(set) var currentMeeting: MeetingEvent?
    @Published private(set) var upcoming: [MeetingEvent] = []
    @Published private(set) var calendarAccess: Bool = false

    private let store = EKEventStore()
    private var timer: Timer?
    private unowned let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// True when the island should stay out of the way.
    var isBusy: Bool {
        guard settings.hideDuringCalls else { return false }
        let device = settings.useMicDetection && (micInUse || cameraInUse)
        let calendar = settings.useCalendar && currentMeeting != nil
        return device || calendar
    }

    /// Actually on a call (mic or camera in use): the island disappears entirely.
    /// A calendar meeting alone only holds pop-ups and the athan until it ends.
    var isOnCall: Bool {
        settings.hideDuringCalls && settings.useMicDetection && (micInUse || cameraInUse)
    }

    var busyReason: String? {
        if settings.useMicDetection && cameraInUse { return "Camera in use" }
        if settings.useMicDetection && micInUse { return "On a call" }
        if settings.useCalendar, let m = currentMeeting {
            return "\(m.title) until \(m.end.formatted(date: .omitted, time: .shortened))"
        }
        return nil
    }

    func start() {
        requestCalendar()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCalendar() }
        }
    }

    func requestCalendar() {
        guard settings.useCalendar else { return }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                self?.calendarAccess = granted
                self?.refreshCalendar()
            }
        }
    }

    private var lastCalendarRefresh = Date.distantPast

    private func poll() {
        let mic = settings.useMicDetection && Self.isAnyInputRunning()
        let cam = settings.useMicDetection && Self.isAnyCameraRunning()
        if mic != micInUse { micInUse = mic }
        if cam != cameraInUse { cameraInUse = cam }
        if Date().timeIntervalSince(lastCalendarRefresh) > 30 { refreshCalendar() }
        else { updateCurrentMeeting() }
    }

    private var todaysEvents: [MeetingEvent] = []
    private var systemEvents: [MeetingEvent] = []
    private var linkEvents: [MeetingEvent] = []
    private var lastLinkFetch = Date.distantPast
    private var fetchedLink = ""
    @Published private(set) var linkStatus: String?

    func refreshCalendar() {
        lastCalendarRefresh = Date()
        if settings.useCalendar, EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            calendarAccess = true
            let now = Date()
            let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                     end: now.addingTimeInterval(18 * 3600), calendars: nil)
            systemEvents = store.events(matching: predicate)
                .filter(Self.looksLikeMeeting)
                .map { MeetingEvent(title: $0.title ?? "Meeting", start: $0.startDate, end: $0.endDate) }
        } else {
            systemEvents = []
        }
        refreshLinkIfNeeded()
        mergeEvents()
    }

    /// Re-download the published calendar every 5 minutes (or right away when the link changes).
    func refreshLinkIfNeeded(force: Bool = false) {
        let link = settings.icsURL.trimmingCharacters(in: .whitespaces)
        guard settings.useCalendar, !link.isEmpty else {
            linkEvents = []; linkStatus = nil; fetchedLink = ""
            return
        }
        guard force || link != fetchedLink || Date().timeIntervalSince(lastLinkFetch) > 300 else { return }
        lastLinkFetch = Date()
        fetchedLink = link
        Task {
            do {
                let events = try await ICSCalendar.fetch(link)
                self.linkEvents = events
                self.linkStatus = "Synced \(events.count) event\(events.count == 1 ? "" : "s") today"
            } catch {
                self.linkStatus = "Couldn't load the calendar link"
            }
            self.mergeEvents()
        }
    }

    private func mergeEvents() {
        // Same meeting can come from both sources; de-duplicate on start/end.
        var seen = Set<String>()
        todaysEvents = (systemEvents + linkEvents)
            .filter { seen.insert("\($0.start.timeIntervalSince1970)-\($0.end.timeIntervalSince1970)").inserted }
            .sorted { $0.start < $1.start }
        updateCurrentMeeting()
    }

    private func updateCurrentMeeting() {
        let now = Date()
        let current = todaysEvents.first { $0.start <= now && $0.end > now }
        if current != currentMeeting { currentMeeting = current }
        let next = todaysEvents.filter { $0.start > now }
        if next != upcoming { upcoming = next }
    }

    private static let videoHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                                     "whereby.com", "around.co", "facetime.apple.com", "chime.aws", "gotomeeting"]

    static func looksLikeMeeting(_ e: EKEvent) -> Bool {
        if e.isAllDay || e.availability == .free || e.status == .canceled { return false }
        if let me = e.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { return false }
        if e.hasAttendees { return true }
        let haystack = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ").lowercased()
        return videoHosts.contains { haystack.contains($0) }
    }

    // MARK: - Device usage

    private static func isAnyInputRunning() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return false }

        for id in ids {
            // Only devices with input streams.
            var streamAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                        mScope: kAudioDevicePropertyScopeInput,
                                                        mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize)
            if streamSize == 0 { continue }

            var runAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &runAddr, 0, nil, &runSize, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    private static func isAnyCameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr else { return false }

        for id in ids {
            var runAddr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var running: UInt32 = 0
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(id, &runAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }
}
