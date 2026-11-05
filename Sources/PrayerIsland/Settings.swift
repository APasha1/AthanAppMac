import Foundation
import ServiceManagement

/// User preferences, persisted to UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var method: CalculationMethod { didSet { save(method.rawValue, "method") } }
    @Published var madhab: AsrMadhab { didSet { save(madhab.rawValue, "madhab") } }

    @Published var useAutoLocation: Bool { didSet { save(useAutoLocation, "useAutoLocation") } }
    @Published var latitude: Double { didSet { save(latitude, "latitude") } }
    @Published var longitude: Double { didSet { save(longitude, "longitude") } }
    @Published var placeName: String { didSet { save(placeName, "placeName") } }

    /// Minutes before each prayer to show a gentle heads-up (0 = off).
    @Published var preReminderMinutes: Int { didSet { save(preReminderMinutes, "preReminderMinutes") } }
    /// Minutes before a prayer's time runs out to remind you if it isn't checked off (0 = off).
    @Published var endReminderMinutes: Int { didSet { save(endReminderMinutes, "endReminderMinutes") } }
    @Published var playAthan: Bool { didSet { save(playAthan, "playAthan") } }
    /// Path to a user-chosen athan audio file. Empty means use the built-in chime.
    @Published var athanPath: String { didSet { save(athanPath, "athanPath") } }
    @Published var fajrAthanPath: String { didSet { save(fajrAthanPath, "fajrAthanPath") } }
    @Published var athanVolume: Double { didSet { save(athanVolume, "athanVolume") } }

    @Published var hideDuringCalls: Bool { didSet { save(hideDuringCalls, "hideDuringCalls") } }
    @Published var useCalendar: Bool { didSet { save(useCalendar, "useCalendar") } }
    @Published var useMicDetection: Bool { didSet { save(useMicDetection, "useMicDetection") } }
    /// Published Outlook/Google calendar link, for calendars not synced into macOS Calendar.
    @Published var icsURL: String { didSet { save(icsURL, "icsURL") } }
    @Published var showWings: Bool { didSet { save(showWings, "showWings") } }
    /// Per-prayer fine-tuning in minutes, to match a mosque timetable or another app.
    @Published var adjustments: [String: Int] { didSet { save(adjustments, "adjustments") } }
    /// true = the island is left out of screenshots, recordings and screen shares.
    /// Fridays: no Dhuhr reminders, since Jummah replaces it.
    @Published var skipFridayDhuhr: Bool { didSet { save(skipFridayDhuhr, "skipFridayDhuhr") } }
    /// Fridays: a reminder to make dua in the last stretch of Asr before Maghrib (0 = off).
    @Published var fridayDuaMinutes: Int { didSet { save(fridayDuaMinutes, "fridayDuaMinutes") } }
    @Published var hideFromCapture: Bool { didSet { save(hideFromCapture, "hideFromCapture") } }
    /// false = click the notch to open the island; true = it opens when the pointer rests on it.
    @Published var openOnHover: Bool { didSet { save(openOnHover, "openOnHover") } }
    /// Seconds the prayer-time glance stays down before tucking back into the notch.
    @Published var glanceSeconds: Int { didSet { save(glanceSeconds, "glanceSeconds") } }

    @Published var launchAtLogin: Bool {
        didSet {
            save(launchAtLogin, "openAtLogin")
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("PrayerIsland: launch-at-login change failed: \(error)")
            }
        }
    }

    /// Re-register on every launch so the login item follows the app if it moves.
    func applyLoginItem() {
        guard launchAtLogin, SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }

    var hasLocation: Bool { latitude != 0 || longitude != 0 }

    init() {
        let d = UserDefaults.standard
        method = CalculationMethod(rawValue: d.string(forKey: "method") ?? "")
            ?? CalculationMethod.suggested(for: Locale.current.region?.identifier)
        madhab = AsrMadhab(rawValue: d.string(forKey: "madhab") ?? "") ?? .standard
        useAutoLocation = d.object(forKey: "useAutoLocation") as? Bool ?? true
        latitude = d.double(forKey: "latitude")
        longitude = d.double(forKey: "longitude")
        placeName = d.string(forKey: "placeName") ?? ""
        preReminderMinutes = d.object(forKey: "preReminderMinutes") as? Int ?? 10
        endReminderMinutes = d.object(forKey: "endReminderMinutes") as? Int ?? 15
        playAthan = d.object(forKey: "playAthan") as? Bool ?? true
        athanPath = d.string(forKey: "athanPath") ?? ""
        fajrAthanPath = d.string(forKey: "fajrAthanPath") ?? ""
        athanVolume = d.object(forKey: "athanVolume") as? Double ?? 0.7
        hideDuringCalls = d.object(forKey: "hideDuringCalls") as? Bool ?? true
        useCalendar = d.object(forKey: "useCalendar") as? Bool ?? true
        useMicDetection = d.object(forKey: "useMicDetection") as? Bool ?? true
        icsURL = d.string(forKey: "icsURL") ?? ""
        adjustments = d.dictionary(forKey: "adjustments") as? [String: Int] ?? [:]
        skipFridayDhuhr = d.object(forKey: "skipFridayDhuhr") as? Bool ?? true
        fridayDuaMinutes = d.object(forKey: "fridayDuaMinutes") as? Int ?? 60
        hideFromCapture = d.object(forKey: "hideFromCapture") as? Bool ?? true
        openOnHover = d.object(forKey: "openOnHover") as? Bool ?? false
        glanceSeconds = d.object(forKey: "glanceSeconds") as? Int ?? 10
        showWings = d.object(forKey: "showWings") as? Bool ?? true
        launchAtLogin = d.object(forKey: "openAtLogin") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}
