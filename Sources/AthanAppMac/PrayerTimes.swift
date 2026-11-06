import Foundation

/// The five daily prayers plus sunrise (shown, but never alerted).
enum Prayer: String, CaseIterable, Codable, Identifiable {
    case fajr, sunrise, dhuhr, asr, maghrib, isha

    var id: String { rawValue }

    var name: String {
        switch self {
        case .fajr: "Fajr"
        case .sunrise: "Sunrise"
        case .dhuhr: "Dhuhr"
        case .asr: "Asr"
        case .maghrib: "Maghrib"
        case .isha: "Isha"
        }
    }

    var arabic: String {
        switch self {
        case .fajr: "الفجر"
        case .sunrise: "الشروق"
        case .dhuhr: "الظهر"
        case .asr: "العصر"
        case .maghrib: "المغرب"
        case .isha: "العشاء"
        }
    }

    var symbol: String {
        switch self {
        case .fajr: "sun.haze.fill"
        case .sunrise: "sunrise.fill"
        case .dhuhr: "sun.max.fill"
        case .asr: "sun.min.fill"
        case .maghrib: "sunset.fill"
        case .isha: "moon.stars.fill"
        }
    }

    var isObligatory: Bool { self != .sunrise }
}

enum CalculationMethod: String, CaseIterable, Codable, Identifiable {
    case isna, mwl, karachi, makkah, egypt, dubai, singapore, turkey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .isna: "ISNA (North America)"
        case .mwl: "Muslim World League"
        case .karachi: "Karachi (Univ. of Islamic Sciences)"
        case .makkah: "Umm al-Qura (Makkah)"
        case .egypt: "Egyptian General Authority"
        case .dubai: "Dubai"
        case .singapore: "Singapore / Malaysia"
        case .turkey: "Diyanet (Turkey)"
        }
    }

    /// Fajr angle, and either an Isha angle or a fixed number of minutes after Maghrib.
    var fajrAngle: Double {
        switch self {
        case .isna: 15
        case .mwl: 18
        case .karachi: 18
        case .makkah: 18.5
        case .egypt: 19.5
        case .dubai: 18.2
        case .singapore: 20
        case .turkey: 18
        }
    }

    var isha: (angle: Double?, minutes: Double?) {
        switch self {
        case .isna: (15, nil)
        case .mwl: (17, nil)
        case .karachi: (18, nil)
        case .makkah: (nil, 90)
        case .egypt: (17.5, nil)
        case .dubai: (18.2, nil)
        case .singapore: (18, nil)
        case .turkey: (17, nil)
        }
    }

    /// Sensible default for the user's region.
    static func suggested(for region: String?) -> CalculationMethod {
        switch region?.uppercased() {
        case "US", "CA", "MX": .isna
        case "PK", "IN", "BD", "AF": .karachi
        case "SA", "YE", "BH", "KW", "QA", "OM": .makkah
        case "EG", "SY", "LB", "IQ", "JO", "LY", "SD": .egypt
        case "AE": .dubai
        case "SG", "MY", "ID", "BN": .singapore
        case "TR": .turkey
        default: .mwl
        }
    }
}

enum AsrMadhab: String, CaseIterable, Codable, Identifiable {
    case standard, hanafi
    var id: String { rawValue }
    var label: String { self == .standard ? "Standard (Shafiʿi, Maliki, Hanbali)" : "Hanafi" }
    var shadowFactor: Double { self == .standard ? 1 : 2 }
}

/// Astronomical prayer time calculation (after the PrayTimes.org algorithm). Runs fully offline.
struct PrayerCalculator {
    var latitude: Double
    var longitude: Double
    var method: CalculationMethod
    var madhab: AsrMadhab

    func times(for date: Date, calendar: Calendar = .current) -> [Prayer: Date] {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let dayStart = calendar.startOfDay(for: date)
        let tz = Double(calendar.timeZone.secondsFromGMT(for: dayStart.addingTimeInterval(12 * 3600))) / 3600
        let jDate = julian(comps.year!, comps.month!, comps.day!) - longitude / (15 * 24)

        // One refinement pass from rough initial guesses (hours).
        var t: [Prayer: Double] = [.fajr: 5, .sunrise: 6, .dhuhr: 12, .asr: 13, .maghrib: 18, .isha: 18]
        t = compute(t, jDate: jDate)

        // Shift from solar to local clock time.
        for key in t.keys { t[key]! += tz - longitude / 15 }

        // High-latitude safety net (angle-based rule).
        let night = fixHour(t[.sunrise]! - t[.maghrib]!)
        t[.fajr] = adjustHighLat(t[.fajr]!, base: t[.sunrise]!, angle: method.fajrAngle, night: night, ccw: true)
        if let ishaAngle = method.isha.angle {
            t[.isha] = adjustHighLat(t[.isha]!, base: t[.maghrib]!, angle: ishaAngle, night: night, ccw: false)
        }
        if let minutes = method.isha.minutes {
            t[.isha] = t[.maghrib]! + minutes / 60
        }
        // Small safety margin for Dhuhr (just past zenith) and Maghrib (past sunset).
        t[.dhuhr]! += 1.0 / 60
        t[.maghrib]! += 1.0 / 60

        // Anchor to UTC midnight rather than local midnight: on a daylight-saving switch day,
        // local midnight is on the old offset and every time after 2 AM would be an hour off.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let utcMidnight = utc.date(from: comps)!

        var result: [Prayer: Date] = [:]
        for (prayer, hours) in t where hours.isFinite {
            // Round up to the next whole minute, like athan apps do, so nothing fires early.
            let minutes = (hours * 60).rounded(.up)
            result[prayer] = utcMidnight.addingTimeInterval((minutes - tz * 60) * 60)
        }
        return result
    }

    // MARK: - Astronomy

    private func compute(_ t: [Prayer: Double], jDate: Double) -> [Prayer: Double] {
        func portion(_ p: Prayer) -> Double { t[p]! / 24 }
        var out: [Prayer: Double] = [:]
        out[.fajr] = sunAngleTime(method.fajrAngle, portion(.fajr), jDate: jDate, ccw: true)
        out[.sunrise] = sunAngleTime(0.833, portion(.sunrise), jDate: jDate, ccw: true)
        out[.dhuhr] = midDay(portion(.dhuhr), jDate: jDate)
        out[.asr] = asrTime(madhab.shadowFactor, portion(.asr), jDate: jDate)
        out[.maghrib] = sunAngleTime(0.833, portion(.maghrib), jDate: jDate, ccw: false)
        out[.isha] = sunAngleTime(method.isha.angle ?? 18, portion(.isha), jDate: jDate, ccw: false)
        return out
    }

    private func sunPosition(_ jd: Double) -> (declination: Double, equation: Double) {
        let d = jd - 2451545.0
        let g = fixAngle(357.529 + 0.98560028 * d)
        let q = fixAngle(280.459 + 0.98564736 * d)
        let l = fixAngle(q + 1.915 * dsin(g) + 0.020 * dsin(2 * g))
        let e = 23.439 - 0.00000036 * d
        let ra = darctan2(dcos(e) * dsin(l), dcos(l)) / 15
        let eqt = q / 15 - fixHour(ra)
        let decl = darcsin(dsin(e) * dsin(l))
        return (decl, eqt)
    }

    private func midDay(_ time: Double, jDate: Double) -> Double {
        fixHour(12 - sunPosition(jDate + time).equation)
    }

    private func sunAngleTime(_ angle: Double, _ time: Double, jDate: Double, ccw: Bool) -> Double {
        let decl = sunPosition(jDate + time).declination
        let noon = midDay(time, jDate: jDate)
        let t = darccos((-dsin(angle) - dsin(decl) * dsin(latitude)) / (dcos(decl) * dcos(latitude))) / 15
        return noon + (ccw ? -t : t)
    }

    private func asrTime(_ factor: Double, _ time: Double, jDate: Double) -> Double {
        let decl = sunPosition(jDate + time).declination
        let angle = -darccot(factor + dtan(abs(latitude - decl)))
        return sunAngleTime(angle, time, jDate: jDate, ccw: false)
    }

    private func adjustHighLat(_ time: Double, base: Double, angle: Double, night: Double, ccw: Bool) -> Double {
        let portion = angle / 60 * night
        let diff = ccw ? fixHour(base - time) : fixHour(time - base)
        if !time.isFinite || diff > portion {
            return base + (ccw ? -portion : portion)
        }
        return time
    }

    private func julian(_ year: Int, _ month: Int, _ day: Int) -> Double {
        var y = Double(year), m = Double(month)
        if m <= 2 { y -= 1; m += 12 }
        let a = floor(y / 100)
        let b = 2 - a + floor(a / 4)
        return floor(365.25 * (y + 4716)) + floor(30.6001 * (m + 1)) + Double(day) + b - 1524.5
    }

    // MARK: - Degree trig helpers

    private func dsin(_ d: Double) -> Double { sin(d * .pi / 180) }
    private func dcos(_ d: Double) -> Double { cos(d * .pi / 180) }
    private func dtan(_ d: Double) -> Double { tan(d * .pi / 180) }
    private func darcsin(_ x: Double) -> Double { asin(x) * 180 / .pi }
    private func darccos(_ x: Double) -> Double { acos(x) * 180 / .pi }
    private func darctan2(_ y: Double, _ x: Double) -> Double { atan2(y, x) * 180 / .pi }
    private func darccot(_ x: Double) -> Double { atan(1 / x) * 180 / .pi }
    private func fixAngle(_ a: Double) -> Double { let r = a.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r }
    private func fixHour(_ h: Double) -> Double { let r = h.truncatingRemainder(dividingBy: 24); return r < 0 ? r + 24 : r }
}
