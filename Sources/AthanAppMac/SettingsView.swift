import EventKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: PrayerStore
    @EnvironmentObject var location: LocationProvider
    @EnvironmentObject var focus: FocusMonitor
    @State private var cityQuery = ""
    @State private var searching = false

    var body: some View {
        Form {
            Section {
                ForEach(store.slots) { slot in
                    HStack {
                        Image(systemName: slot.prayer.symbol)
                            .foregroundStyle(slot.prayer.gradient)
                            .frame(width: 22)
                        Text(slot.prayer.name)
                        Text(slot.prayer.arabic).foregroundStyle(.secondary)
                        Spacer()
                        if slot.prayed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        Text(slot.time.formatted(date: .omitted, time: .shortened))
                            .monospacedDigit()
                            .fontWeight(slot.state == .current ? .semibold : .regular)
                    }
                }
            } header: {
                HStack {
                    Text("Today")
                    Spacer()
                    Text(store.hijriDate).foregroundStyle(.secondary)
                }
            }

            Section("Location") {
                Toggle("Use my current location", isOn: $settings.useAutoLocation)
                    .onChange(of: settings.useAutoLocation) { _, on in if on { location.start() } }
                LabeledContent("Current", value: settings.placeName.isEmpty ? "Not set" : settings.placeName)
                HStack {
                    TextField("City, e.g. London or Lahore", text: $cityQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(findCity)
                    Button(searching ? "Finding…" : "Set City", action: findCity)
                        .disabled(cityQuery.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                if let err = location.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Calculation") {
                Picker("Method", selection: $settings.method) {
                    ForEach(CalculationMethod.allCases) { Text($0.label).tag($0) }
                }
                Picker("Asr", selection: $settings.madhab) {
                    ForEach(AsrMadhab.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                ForEach(Prayer.allCases) { p in
                    Stepper(value: Binding(get: { settings.adjustments[p.rawValue] ?? 0 },
                                           set: { settings.adjustments[p.rawValue] = $0 == 0 ? nil : $0 }),
                            in: -30...30) {
                        HStack {
                            Text(p.name)
                            Spacer()
                            let m = settings.adjustments[p.rawValue] ?? 0
                            Text(m == 0 ? "No change" : String(format: "%+d min", m))
                                .monospacedDigit()
                                .foregroundStyle(m == 0 ? .secondary : .primary)
                        }
                    }
                }
            } header: {
                Text("Fine-tune Times")
            } footer: {
                Text("Nudge any prayer by a few minutes to match your mosque's timetable or another athan app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reminders") {
                Picker("Heads-up before each prayer", selection: $settings.preReminderMinutes) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 20, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Picker("Remind me before a prayer's time ends", selection: $settings.endReminderMinutes) {
                    Text("Off").tag(0)
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) minutes, if not checked off").tag($0) }
                }
                Toggle("Skip Dhuhr on Fridays (Jummah)", isOn: $settings.skipFridayDhuhr)
                Picker("Friday dua reminder", selection: $settings.fridayDuaMinutes) {
                    Text("Off").tag(0)
                    Text("Last 30 min before Maghrib").tag(30)
                    Text("Last hour before Maghrib").tag(60)
                    Text("Last 90 min before Maghrib").tag(90)
                }
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Also play when the screen is off or locked", isOn: $settings.soundWhenAway)
                    .disabled(!settings.playSounds)
                Toggle("Play athan at prayer time", isOn: $settings.playAthan)
                    .disabled(!settings.playSounds)
                AudioPickerRow(title: "Athan sound", path: $settings.athanPath)
                AudioPickerRow(title: "Fajr athan (optional)", path: $settings.fajrAthanPath)
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $settings.athanVolume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Preview Alert") { store.testAlert() }
                    Button("Preview Heads-up") { store.testPeek() }
                    if store.player.isPlaying { Button("Stop Sound") { store.stopAthan() } }
                }
            }

            Section {
                Toggle("Stay hidden during meetings and calls", isOn: $settings.hideDuringCalls)
                Toggle("Use my calendar", isOn: $settings.useCalendar)
                    .onChange(of: settings.useCalendar) { _, on in if on { focus.requestCalendar() } }
                    .disabled(!settings.hideDuringCalls)
                if settings.useCalendar && EKEventStore.authorizationStatus(for: .event) != .fullAccess {
                    HStack {
                        Text("Calendar access needed").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                        .controlSize(.small)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Outlook calendar link (ICS), optional", text: $settings.icsURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { focus.refreshLinkIfNeeded(force: true) }
                    Text(focus.linkStatus ?? "Only needed if your Outlook calendar isn't added in System Settings → Internet Accounts. Get the link from Outlook on the web: Settings → Calendar → Shared calendars → Publish a calendar → ICS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.useCalendar || !settings.hideDuringCalls)
                Toggle("Detect calls from microphone and camera use", isOn: $settings.useMicDetection)
                    .disabled(!settings.hideDuringCalls)
                LabeledContent("Right now") {
                    Text(focus.busyReason.map { "Quiet: \($0)" } ?? "Free")
                        .foregroundStyle(focus.isBusy ? .orange : .green)
                }
            } header: {
                Text("Meetings")
            } footer: {
                Text("While you're in a meeting the island hides itself, and any prayer that begins is held until about 40 seconds after the call ends. The island is always excluded from screenshots and screen sharing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Open the island", selection: $settings.openOnHover) {
                    Text("When I click the notch").tag(false)
                    Text("When I hover over the notch").tag(true)
                }
                Picker("Prayer-time glance stays for", selection: $settings.glanceSeconds) {
                    ForEach([6, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle("Hide from screenshots, recordings and screen sharing", isOn: $settings.hideFromCapture)
                Toggle("Show next prayer beside the notch", isOn: $settings.showWings)
                Toggle("Open at login", isOn: $settings.launchAtLogin)
            } header: {
                Text("Island")
            } footer: {
                Text("It only drops down by itself for the prayer-time glance and the heads-up, then tucks back into the notch. Everywhere outside the black shape, clicks pass straight through to your apps. Turn off the side labels if they cover menu bar items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560)
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
}

struct AudioPickerRow: View {
    let title: String
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(path.isEmpty ? "Soft chime" : URL(fileURLWithPath: path).lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.audio]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
                if !path.isEmpty {
                    Button { path = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
