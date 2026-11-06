import Foundation

/// Reads a published calendar (.ics) link, e.g. Outlook on the web → Settings → Calendar →
/// Shared calendars → Publish a calendar → ICS. Handles the common recurrence rules Outlook emits.
enum ICSCalendar {
    static func fetch(_ urlString: String, around now: Date = Date()) async throws -> [MeetingEvent] {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("webcal://") { s = "https://" + s.dropFirst("webcal://".count) }
        guard let url = URL(string: s) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return parse(text, from: now.addingTimeInterval(-12 * 3600), to: now.addingTimeInterval(18 * 3600))
    }

    static func parse(_ text: String, from windowStart: Date, to windowEnd: Date) -> [MeetingEvent] {
        // Unfold continuation lines.
        let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")

        var events: [MeetingEvent] = []
        var overrides: [String: Set<Date>] = [:] // UID → occurrence starts replaced by a RECURRENCE-ID entry
        var current: [String: (params: String, value: String)]?
        var exdates: [Date] = []
        var parsed: [(props: [String: (params: String, value: String)], exdates: [Date])] = []

        for line in unfolded.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line == "BEGIN:VEVENT" { current = [:]; exdates = []; continue }
            if line == "END:VEVENT" {
                if let c = current { parsed.append((c, exdates)) }
                current = nil
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let head = String(line[..<colon]), value = String(line[line.index(after: colon)...])
            let parts = head.split(separator: ";", maxSplits: 1).map(String.init)
            let name = parts[0].uppercased(), params = parts.count > 1 ? parts[1] : ""
            if name == "EXDATE" {
                for v in value.split(separator: ",") { if let d = date(String(v), params: params) { exdates.append(d) } }
            } else if current![name] == nil {
                current![name] = (params, value)
            }
        }

        for (props, _) in parsed {
            if let uid = props["UID"]?.value, let rid = props["RECURRENCE-ID"], let d = date(rid.value, params: rid.params) {
                overrides[uid, default: []].insert(d)
            }
        }

        for (props, exdates) in parsed {
            guard let ds = props["DTSTART"], let start = date(ds.value, params: ds.params) else { continue }
            if ds.params.contains("VALUE=DATE") && !ds.value.contains("T") { continue } // all-day
            if props["STATUS"]?.value.uppercased() == "CANCELLED" { continue }
            if props["TRANSP"]?.value.uppercased() == "TRANSPARENT" { continue }
            if let busy = props["X-MICROSOFT-CDO-BUSYSTATUS"]?.value.uppercased(), busy == "FREE" { continue }
            let end = props["DTEND"].flatMap { date($0.value, params: $0.params) } ?? start.addingTimeInterval(1800)
            let duration = end.timeIntervalSince(start)
            let title = unescape(props["SUMMARY"]?.value ?? "Meeting")

            var starts = [start]
            if let rule = props["RRULE"]?.value, props["RECURRENCE-ID"] == nil {
                starts = expand(rule: rule, start: start, until: windowEnd)
                let skip = Set(exdates).union(overrides[props["UID"]?.value ?? ""] ?? [])
                starts.removeAll { skip.contains($0) }
            }
            for s in starts where s < windowEnd && s.addingTimeInterval(duration) > windowStart {
                events.append(MeetingEvent(title: title, start: s, end: s.addingTimeInterval(duration)))
            }
        }
        return events.sorted { $0.start < $1.start }
    }

    // MARK: - Recurrence

    private static func expand(rule: String, start: Date, until windowEnd: Date) -> [Date] {
        var fields: [String: String] = [:]
        for part in rule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0].uppercased()] = kv[1] }
        }
        let freq = fields["FREQ"] ?? ""
        let interval = max(1, Int(fields["INTERVAL"] ?? "1") ?? 1)
        let count = fields["COUNT"].flatMap { Int($0) }
        let until = fields["UNTIL"].flatMap { date($0, params: "") }
        let limit = min(until ?? .distantFuture, windowEnd)
        let cal = Calendar.current
        let dayCodes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        let byDay = (fields["BYDAY"] ?? "").split(separator: ",").compactMap { dayCodes[String($0.suffix(2))] }

        var out: [Date] = []
        var produced = 0
        func emit(_ d: Date) -> Bool {
            if d > limit { return false }
            if let count, produced >= count { return false }
            produced += 1
            out.append(d)
            return true
        }

        switch freq {
        case "DAILY":
            var d = start
            while emit(d) { d = cal.date(byAdding: .day, value: interval, to: d)! }
        case "WEEKLY":
            let days = byDay.isEmpty ? [cal.component(.weekday, from: start)] : byDay.sorted()
            var weekStart = cal.dateInterval(of: .weekOfYear, for: start)!.start
            let time = cal.dateComponents([.hour, .minute, .second], from: start)
            outer: while weekStart <= limit {
                for wd in days {
                    var c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)
                    c.weekday = wd; c.hour = time.hour; c.minute = time.minute; c.second = time.second
                    guard let d = cal.date(from: c), d >= start else { continue }
                    if !emit(d) { break outer }
                }
                weekStart = cal.date(byAdding: .weekOfYear, value: interval, to: weekStart)!
            }
        case "MONTHLY":
            var d = start
            while emit(d) { d = cal.date(byAdding: .month, value: interval, to: d)! }
        case "YEARLY":
            var d = start
            while emit(d) { d = cal.date(byAdding: .year, value: interval, to: d)! }
        default:
            out = [start]
        }
        return out
    }

    // MARK: - Dates

    private static func date(_ value: String, params: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.hasSuffix("Z") {
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else if v.contains("T") {
            f.timeZone = timeZone(fromParams: params)
            f.dateFormat = "yyyyMMdd'T'HHmmss"
        } else {
            f.timeZone = .current
            f.dateFormat = "yyyyMMdd"
        }
        return f.date(from: v)
    }

    private static func timeZone(fromParams params: String) -> TimeZone {
        guard let r = params.range(of: "TZID=") else { return .current }
        var id = String(params[r.upperBound...])
        if let semi = id.firstIndex(of: ";") { id = String(id[..<semi]) }
        id = id.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return TimeZone(identifier: id) ?? windowsZones[id].flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// Outlook writes Windows time zone names.
    private static let windowsZones: [String: String] = [
        "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver", "US Mountain Standard Time": "America/Phoenix",
        "Pacific Standard Time": "America/Los_Angeles", "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu", "Atlantic Standard Time": "America/Halifax",
        "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik", "UTC": "UTC",
        "W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest",
        "Romance Standard Time": "Europe/Paris", "Central European Standard Time": "Europe/Warsaw",
        "E. Europe Standard Time": "Europe/Bucharest", "FLE Standard Time": "Europe/Kiev",
        "Turkey Standard Time": "Europe/Istanbul", "Arab Standard Time": "Asia/Riyadh",
        "Arabian Standard Time": "Asia/Dubai", "Egypt Standard Time": "Africa/Cairo",
        "Pakistan Standard Time": "Asia/Karachi", "India Standard Time": "Asia/Kolkata",
        "Bangladesh Standard Time": "Asia/Dhaka", "Singapore Standard Time": "Asia/Singapore",
        "China Standard Time": "Asia/Shanghai", "Tokyo Standard Time": "Asia/Tokyo",
        "AUS Eastern Standard Time": "Australia/Sydney", "Canada Central Standard Time": "America/Regina",
    ]

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
