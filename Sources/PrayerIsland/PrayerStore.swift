import Combine
import Foundation

/// What the island is currently showing.
enum IslandMode: Equatable {
    /// Notch + small wings with the next prayer and countdown.
    case compact
    /// A short-lived heads-up that slides out and goes away by itself.
    case peek(Peek)
    /// It's prayer time. Stays until you act on it.
    case alert(Prayer, deferred: Bool)
}

struct Peek: Equatable {
    let prayer: Prayer
    let title: String
    let subtitle: String
    let symbol: String
    /// Shows a "Prayed" button right on the glance.
    var canMarkPrayed = false
    /// Still shown when an app is full screen.
    var important = false
}

struct PrayerSlot: Identifiable {
    enum State { case past, current, upcoming }
    let prayer: Prayer
    let time: Date
    let state: State
    let prayed: Bool
    var id: Prayer { prayer }
}

/// The brain: prayer times, countdown, when to alert, and what to do around meetings.
@MainActor
final class PrayerStore: ObservableObject {
    let settings: AppSettings
    let focus: FocusMonitor
    let player = AthanPlayer()

    @Published private(set) var now = Date()
    @Published private(set) var today: [Prayer: Date] = [:]
    @Published private(set) var tomorrowFajr: Date?
    @Published var mode: IslandMode = .compact
    @Published private(set) var deferred: [Prayer] = []
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var prayedKeys: Set<String> = []

    private var handledKeys: Set<String> = []
    private var snoozed: [Prayer: Date] = [:]
    private var computedFor: Date?
    private var tick: Timer?
    private var peekTask: Task<Void, Never>?
    private var alertMinimizeTask: Task<Void, Never>?
    private var freeSince: Date?
    /// When the most recent call or meeting began.
    private(set) var busySince: Date?
    private var wasBusy = false
    private var bag = Set<AnyCancellable>()
    /// Set by the window controller; keeps a glance open while you're interacting with it.
    var isPointerOnIsland: () -> Bool = { false }

    init(settings: AppSettings, focus: FocusMonitor) {
        self.settings = settings
        self.focus = focus
        prayedKeys = Set(UserDefaults.standard.stringArray(forKey: "prayedKeys") ?? [])

        // Recompute whenever calculation inputs change.
        Publishers.MergeMany(
            settings.$method.map { _ in () }.eraseToAnyPublisher(),
            settings.$madhab.map { _ in () }.eraseToAnyPublisher(),
            settings.$latitude.map { _ in () }.eraseToAnyPublisher(),
            settings.$longitude.map { _ in () }.eraseToAnyPublisher(),
            settings.$adjustments.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
        .sink { [weak self] in self?.recompute(force: true) }
        .store(in: &bag)

        Publishers.Merge3(focus.objectWillChange, player.objectWillChange, settings.objectWillChange)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    func start() {
        recompute(force: true)
        // Don't fire alerts for prayers that already began before launch.
        let cutoff = Date().addingTimeInterval(-90)
        for (p, t) in today where t < cutoff { handledKeys.insert(key(p, t)) }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(tick!, forMode: .common)
    }

    // MARK: - Derived values

    var slots: [PrayerSlot] {
        let current = currentPrayer
        return Prayer.allCases.compactMap { p in
            guard let t = today[p] else { return nil }
            let state: PrayerSlot.State = p == current?.prayer && current?.start == t ? .current : (t <= now ? .past : .upcoming)
            return PrayerSlot(prayer: p, time: t, state: state, prayed: isPrayed(p, on: t))
        }
    }

    /// The next prayer time that hasn't started yet (rolls over to tomorrow's Fajr).
    var next: (prayer: Prayer, time: Date)? {
        if let p = Prayer.allCases.first(where: { (today[$0] ?? .distantPast) > now }) { return (p, today[p]!) }
        if let f = tomorrowFajr { return (.fajr, f) }
        return nil
    }

    /// The obligatory prayer whose window we're in, if any.
    var currentPrayer: (prayer: Prayer, start: Date, end: Date)? {
        let ordered = Prayer.allCases.compactMap { p in today[p].map { (p, $0) } }
        guard let idx = ordered.lastIndex(where: { $0.1 <= now }) else {
            return nil // before Fajr: still in last night's Isha, which we don't track
        }
        let (p, start) = ordered[idx]
        guard p.isObligatory else { return nil } // between sunrise and Dhuhr
        let end: Date
        if idx + 1 < ordered.count {
            end = ordered[idx + 1].1
        } else {
            // Isha runs until the middle of the night: halfway from Maghrib to tomorrow's Fajr.
            let fajr = tomorrowFajr ?? start.addingTimeInterval(9 * 3600)
            let maghrib = today[.maghrib] ?? start
            end = maghrib.addingTimeInterval(fajr.timeIntervalSince(maghrib) / 2)
        }
        return (p, start, end)
    }

    /// Fraction of the time elapsed between the previous prayer and the next one.
    var progressToNext: Double {
        guard let next else { return 0 }
        let prev = Prayer.allCases.compactMap { today[$0] }.filter { $0 <= now }.max()
            ?? Calendar.current.startOfDay(for: now)
        let total = next.time.timeIntervalSince(prev)
        return total > 0 ? min(1, max(0, now.timeIntervalSince(prev) / total)) : 0
    }

    var isBusy: Bool { focus.isBusy }
    var isOnCall: Bool { focus.isOnCall }
    var isPaused: Bool { (pausedUntil ?? .distantPast) > now }

    func isPrayed(_ p: Prayer, on time: Date) -> Bool { prayedKeys.contains(key(p, time)) }

    /// Prayers that get no reminders at all (Dhuhr on Fridays, for Jummah).
    func isSkipped(_ p: Prayer, on time: Date) -> Bool {
        settings.skipFridayDhuhr && p == .dhuhr && Calendar.current.component(.weekday, from: time) == 6
    }

    /// Needs a reminder: an obligatory prayer that's neither prayed nor skipped.
    func needsReminder(_ p: Prayer, on time: Date) -> Bool {
        p.isObligatory && !isPrayed(p, on: time) && !isSkipped(p, on: time)
    }

    var hijriDate: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .islamicUmmAlQura)
        f.dateFormat = "d MMMM y"
        return f.string(from: now) + " AH"
    }

    // MARK: - Actions

    func markPrayed(_ p: Prayer) {
        guard let t = today[p] else { return }
        prayedKeys.insert(key(p, t))
        persistPrayed()
        deferred.removeAll { $0 == p }
        snoozed[p] = nil
        if case .alert(let shown, _) = mode, shown == p { dismissAlert() }
    }

    func togglePrayed(_ p: Prayer) {
        guard let t = today[p] else { return }
        let k = key(p, t)
        if prayedKeys.contains(k) { prayedKeys.remove(k) } else { prayedKeys.insert(k) }
        persistPrayed()
    }

    func snooze(_ p: Prayer, minutes: Int = 10) {
        snoozed[p] = Date().addingTimeInterval(TimeInterval(minutes * 60))
        dismissAlert()
    }

    func dismissAlert() {
        player.stop()
        alertMinimizeTask?.cancel()
        set(.compact)
    }

    func stopAthan() { player.stop() }

    func pause(for minutes: Int?) {
        pausedUntil = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        if isPaused, case .alert = mode { dismissAlert() }
    }

    /// Preview the alert from the menu, ignoring meetings.
    func testAlert() {
        let p = currentPrayer?.prayer ?? next?.prayer ?? .dhuhr
        showAlert(p, deferred: false)
    }

    func testPeek() {
        guard let n = next else { return }
        showPeek(Peek(prayer: n.prayer, title: "\(n.prayer.name) in \(Self.short(n.time.timeIntervalSince(now)))",
                      subtitle: "at \(n.time.formatted(date: .omitted, time: .shortened))", symbol: n.prayer.symbol))
    }

    // MARK: - Engine

    private func step() {
        now = Date()
        recompute(force: false)
        handleBusyTransitions()

        guard settings.hasLocation, !isPaused else { return }

        // 1. Prayer time reached (or a snooze ran out).
        let open = currentPrayer
        for p in Prayer.allCases where p.isObligatory {
            guard let t = today[p], t <= now, needsReminder(p, on: t) else { continue }
            let k = key(p, t)
            let snoozeDue = snoozed[p].map { $0 <= now } ?? false
            guard !handledKeys.contains(k) || snoozeDue else { continue }
            handledKeys.insert(k)
            snoozed[p] = nil
            // Its time already ended (e.g. the Mac was asleep through it): nothing to remind about now.
            guard open?.prayer == p, open?.start == t else { continue }
            if isBusy {
                if !deferred.contains(p) { deferred.append(p) }
            } else {
                // More than a few minutes late (just woke up, or a snooze): a quiet reminder, no athan.
                showAlert(p, deferred: now.timeIntervalSince(t) > 5 * 60)
            }
        }

        // A prayer running out while you're on a call: remind you as soon as the call ends.
        if isBusy, settings.endReminderMinutes > 0, let cur = currentPrayer, needsReminder(cur.prayer, on: cur.start),
           cur.end.timeIntervalSince(now) <= Double(settings.endReminderMinutes * 60), !deferred.contains(cur.prayer) {
            deferred.append(cur.prayer)
            handledKeys.insert("end-" + key(cur.prayer, cur.start))
        }

        guard !isBusy, case .compact = mode else { return }

        // Fridays: the hour of dua at the end of Asr. If a call or meeting covers the start,
        // it waits (the guard above) and shows once you're free, as long as Maghrib is still ahead.
        if settings.fridayDuaMinutes > 0, Calendar.current.component(.weekday, from: now) == 6,
           let asr = today[.asr], let maghrib = today[.maghrib] {
            let from = max(asr, maghrib.addingTimeInterval(-Double(settings.fridayDuaMinutes * 60)))
            let k = "dua-" + key(.asr, asr)
            let settled = freeSince.map { now.timeIntervalSince($0) >= 40 } ?? true
            if now >= from, maghrib.timeIntervalSince(now) > 120, settled, !handledKeys.contains(k) {
                handledKeys.insert(k)
                showPeek(Peek(prayer: .asr, title: "Friday: make dua now",
                              subtitle: "Duas are accepted in this hour · until \(maghrib.formatted(date: .omitted, time: .shortened))",
                              symbol: "sparkles", important: true))
                return
            }
        }

        // 2. Heads-up a few minutes before the next prayer.
        if settings.preReminderMinutes > 0, let n = next, needsReminder(n.prayer, on: n.time) {
            let lead = n.time.timeIntervalSince(now)
            let k = "pre-" + key(n.prayer, n.time)
            if lead <= Double(settings.preReminderMinutes * 60), lead > 30, !handledKeys.contains(k) {
                handledKeys.insert(k)
                showPeek(Peek(prayer: n.prayer, title: "\(n.prayer.name) in \(Self.short(lead))",
                              subtitle: "at \(n.time.formatted(date: .omitted, time: .shortened))",
                              symbol: n.prayer.symbol))
                return
            }
        }

        // 3. Calendar-aware: a meeting is about to start while the current prayer is still unprayed.
        if let cur = currentPrayer, needsReminder(cur.prayer, on: cur.start),
           let meeting = focus.upcoming.first, settings.useCalendar {
            let untilMeeting = meeting.start.timeIntervalSince(now)
            let k = "mtg-\(meeting.start.timeIntervalSince1970)-" + key(cur.prayer, cur.start)
            if untilMeeting > 60, untilMeeting <= 12 * 60, !handledKeys.contains(k) {
                handledKeys.insert(k)
                let endsDuring = cur.end <= meeting.end
                showPeek(Peek(prayer: cur.prayer,
                              title: "Pray \(cur.prayer.name) before \(meeting.title)?",
                              subtitle: endsDuring
                                ? "It starts in \(Self.short(untilMeeting)), and \(cur.prayer.name) ends during it"
                                : "It starts in \(Self.short(untilMeeting))",
                              symbol: "calendar.badge.clock"))
                return
            }
        }

        // 4. The current prayer's window is about to close.
        if let cur = currentPrayer, needsReminder(cur.prayer, on: cur.start) {
            let left = cur.end.timeIntervalSince(now)
            let k = "end-" + key(cur.prayer, cur.start)
            if settings.endReminderMinutes > 0, left <= Double(settings.endReminderMinutes * 60), left > 60,
               !handledKeys.contains(k) {
                handledKeys.insert(k)
                showPeek(Peek(prayer: cur.prayer, title: "\(cur.prayer.name) ends in \(Self.short(left))",
                              subtitle: "Not checked off yet · ends \(cur.end.formatted(date: .omitted, time: .shortened))",
                              symbol: "hourglass", canMarkPrayed: true))
            }
        }
    }

    /// Hide during calls; when a call ends (and stays ended), surface whatever was missed.
    private func handleBusyTransitions() {
        let busy = isBusy
        if busy && !wasBusy {
            freeSince = nil
            busySince = now
            if case .alert(let p, _) = mode {
                player.stop()
                if !deferred.contains(p) { deferred.append(p) }
            }
            peekTask?.cancel()
            set(.compact)
        }
        if !busy && wasBusy { freeSince = now }
        wasBusy = busy

        // Wait ~40s after the call so back-to-back calls or a quick mic blip don't trigger it.
        guard !busy, let since = freeSince, now.timeIntervalSince(since) >= 40, !deferred.isEmpty else { return }
        freeSince = nil
        let missed = deferred
        deferred = []
        // Only remind about the prayer whose window is still open.
        guard let cur = currentPrayer, missed.contains(cur.prayer), needsReminder(cur.prayer, on: cur.start), !isPaused else { return }
        showAlert(cur.prayer, deferred: true)
    }

    private func showAlert(_ p: Prayer, deferred isDeferred: Bool) {
        peekTask?.cancel()
        set(.alert(p, deferred: isDeferred))
        if settings.playAthan && !isDeferred {
            let path = p == .fajr && !settings.fajrAthanPath.isEmpty ? settings.fajrAthanPath : settings.athanPath
            player.play(path: path, volume: settings.athanVolume)
        } else {
            player.chime(volume: settings.athanVolume * 0.6)
        }
        // A glance: tuck back into the notch after a few seconds unless the pointer is on it.
        // The athan keeps playing, and the wing keeps a dot until the prayer is marked.
        alertMinimizeTask?.cancel()
        alertMinimizeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(max(4, self.settings.glanceSeconds)))
            while !Task.isCancelled, self.isPointerOnIsland() {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled, case .alert = self.mode else { return }
            self.set(.compact)
        }
    }

    private func showPeek(_ peek: Peek) {
        peekTask?.cancel()
        set(.peek(peek))
        player.chime(volume: settings.athanVolume * 0.35)
        peekTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(max(4, self.settings.glanceSeconds)))
            while !Task.isCancelled, self.isPointerOnIsland() {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled, case .peek = self.mode else { return }
            self.set(.compact)
        }
    }

    private func set(_ m: IslandMode) {
        if mode != m { mode = m }
    }

    private func recompute(force: Bool) {
        let day = Calendar.current.startOfDay(for: now)
        guard force || computedFor != day else { return }
        computedFor = day
        guard settings.hasLocation else { today = [:]; tomorrowFajr = nil; return }
        let calc = PrayerCalculator(latitude: settings.latitude, longitude: settings.longitude,
                                    method: settings.method, madhab: settings.madhab)
        today = adjusted(calc.times(for: now))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        tomorrowFajr = adjusted(calc.times(for: tomorrow))[.fajr]
        if force {
            // Times moved (new location/method): don't alert for anything already in the past.
            let cutoff = now.addingTimeInterval(-90)
            for (p, t) in today where t < cutoff { handledKeys.insert(key(p, t)) }
        }
    }

    private func adjusted(_ times: [Prayer: Date]) -> [Prayer: Date] {
        times.reduce(into: [:]) { out, entry in
            out[entry.key] = entry.value.addingTimeInterval(TimeInterval((settings.adjustments[entry.key.rawValue] ?? 0) * 60))
        }
    }

    private func key(_ p: Prayer, _ t: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "\(f.string(from: t))-\(p.rawValue)"
    }

    private func persistPrayed() {
        // Keep about two weeks of history.
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: now)!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let floor = f.string(from: cutoff)
        prayedKeys = prayedKeys.filter { String($0.prefix(10)) >= floor }
        UserDefaults.standard.set(Array(prayedKeys), forKey: "prayedKeys")
    }

    // MARK: - Formatting

    static func short(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval.rounded()))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m) min" }
        return "\(s)s"
    }

    /// Compact countdown for the wing: "2:14:09" / "14:09".
    static func clock(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
