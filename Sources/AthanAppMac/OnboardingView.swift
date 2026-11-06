import EventKit
import SwiftUI

/// First-run setup: permissions, location, calculation, calendar. Settings covers everything afterwards.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, location, calculation, meetings, sound, done }

    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: PrayerStore
    @EnvironmentObject var location: LocationProvider
    @EnvironmentObject var focus: FocusMonitor
    @State var step: Step = .welcome
    @State private var cityQuery = ""
    @State private var searching = false
    @State private var locating = false
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .location: locationStep
                case .calculation: calculation
                case .meetings: meetings
                case .sound: sound
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))

            footer
        }
        .frame(width: 520, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 54))
                .foregroundStyle(Prayer.isha.gradient)
                .frame(width: 104, height: 104)
                .background(Circle().fill(.black))
                .padding(.top, 10)
            Text("Athan App Mac").font(.system(size: 30, weight: .bold))
            Text("Prayer times that live in your notch.")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                feature("clock.badge.checkmark", "A glance at every prayer time", "It drops down with the athan, then tucks itself away.")
                feature("video.slash", "Quiet in calls and meetings", "It waits, then reminds you once the call ends.")
                feature("eye.slash", "Private", "Hidden from screenshots and screen shares. Nothing leaves your Mac.")
            }
            .padding(.top, 14)
        }
    }

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("location.fill", "Where are you?", "Prayer times depend on where you are, so this is the one thing the app needs.")

            Button {
                settings.useAutoLocation = true
                locating = true
                location.start()
            } label: {
                Label(locating && !settings.hasLocation ? "Finding you…" : "Use My Current Location", systemImage: "location.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            HStack {
                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                Text("or").font(.caption).foregroundStyle(.secondary)
                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
            }

            HStack {
                TextField("Type a city, e.g. London or Lahore", text: $cityQuery)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit(findCity)
                Button(searching ? "Finding…" : "Set", action: findCity)
                    .controlSize(.large)
                    .disabled(cityQuery.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }

            if let err = location.lastError, !settings.hasLocation {
                Text(err).font(.callout).foregroundStyle(.orange)
            }

            if settings.hasLocation {
                card {
                    Label(settings.placeName, systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text(Self.timeZoneSummary).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var calculation: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("sun.horizon.fill", "How should times be worked out?", "We picked the usual method for your region. Match it to your mosque if it differs.")

            card {
                Picker("Method", selection: $settings.method) {
                    ForEach(CalculationMethod.allCases) { Text($0.label).tag($0) }
                }
                Picker("Asr", selection: $settings.madhab) {
                    ForEach(AsrMadhab.allCases) { Text($0.label).tag($0) }
                }
            }

            Text("TODAY IN \(settings.placeName.uppercased())").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(store.slots) { slot in
                    VStack(spacing: 6) {
                        Image(systemName: slot.prayer.symbol).foregroundStyle(slot.prayer.gradient)
                        Text(slot.prayer.name).font(.caption.weight(.medium))
                        Text(slot.time.formatted(date: .omitted, time: .shortened))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
                }
            }
            Text("Off by a minute or two from your mosque? Fine-tune any prayer later in Settings.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var meetings: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("calendar.badge.clock", "Stay quiet in meetings", "The island hides during calls, and any prayer that comes in waits until you're done.")

            card {
                Toggle("Hide during calls (detected from mic and camera use)", isOn: $settings.hideDuringCalls)
                Text("No permission needed. It only checks whether they're in use, and never records or listens.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use my calendar").font(.headline)
                        Text("Hold alerts during meetings with attendees or a call link. Works with iCloud, Google and Outlook calendars in the Calendar app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if calendarGranted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow") {
                            settings.useCalendar = true
                            focus.requestCalendar()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var sound: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("speaker.wave.2.fill", "Sound", "Hear the athan when it's time to pray, or keep it silent and just see the island drop down.")

            card {
                Toggle("Play sounds", isOn: $settings.playSounds).font(.headline)
                if settings.playSounds {
                    Picker("At prayer time", selection: $settings.playAthan) {
                        Text("Athan").tag(true)
                        Text("Soft chime").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if settings.playAthan {
                        AudioPickerRow(title: "Athan audio", path: $settings.athanPath)
                        Text("Choose an athan recording (MP3 or M4A). Until you do, a soft chime plays.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $settings.athanVolume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        Button(store.player.isPlaying ? "Stop" : "Preview") {
                            if store.player.isPlaying { store.stopAthan() }
                            else if settings.playAthan { store.player.play(path: settings.athanPath, volume: settings.athanVolume) }
                            else { store.player.chime(volume: settings.athanVolume * 0.6) }
                        }
                    }
                }
            }

            if settings.playSounds {
                card {
                    Toggle("Also play when my screen is off or locked", isOn: $settings.soundWhenAway).font(.headline)
                    Text("When this is off, the app stays silent while your Mac's display is asleep or locked, so it won't go off in a quiet room or a meeting you've stepped into.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var done: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .padding(.top, 20)
            Text("You're all set").font(.system(size: 28, weight: .bold))
            Text("Look at your notch: the next prayer is there now.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                feature("cursorarrow.click", "Click the notch", "Opens today's times. Tap a prayer to check it off.")
                feature("moon.stars.fill", "The moon in your menu bar", "Settings, pause, preview and quit.")
                feature("gearshape", "Change anything later", "Sounds, reminders, Friday options and more are in Settings.")
            }
            .padding(.top, 10)
            Toggle("Open Athan App Mac when I log in", isOn: $settings.launchAtLogin)
                .padding(.top, 8)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { go(-1) }.controlSize(.large)
            }
            Spacer()
            HStack(spacing: 7) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            Spacer()
            Button(primaryTitle) {
                // Skipping the calendar step means no calendar prompt later either.
                if step == .meetings && !calendarGranted { settings.useCalendar = false }
                step == .done ? finish() : go(1)
            }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(step == .location && !settings.hasLocation)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(.bar)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .meetings: calendarGranted || !settings.useCalendar ? "Continue" : "Skip"
        case .done: "Start"
        default: "Continue"
        }
    }

    private var calendarGranted: Bool { focus.calendarAccess || EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    private func go(_ delta: Int) {
        if let next = Step(rawValue: step.rawValue + delta) { step = next }
    }

    // MARK: - Pieces

    private func header(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Prayer.maghrib.gradient)
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Prayer.isha.gradient).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    private func findCity() {
        let q = cityQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task {
            if let (coord, name) = await location.search(q) {
                settings.useAutoLocation = false
                settings.latitude = coord.latitude
                settings.longitude = coord.longitude
                settings.placeName = name
                location.lastError = nil
                cityQuery = ""
            }
            searching = false
        }
    }

    /// e.g. "Eastern Time · Clocks change Mar 14, 2027. Prayer times follow automatically."
    static var timeZoneSummary: String {
        let tz = TimeZone.current
        let name = tz.localizedName(for: .generic, locale: .current) ?? tz.identifier
        guard let change = tz.nextDaylightSavingTimeTransition else {
            return "\(name) · No daylight saving here."
        }
        return "\(name) · Clocks change \(change.formatted(date: .abbreviated, time: .omitted)). Prayer times adjust automatically."
    }
}
