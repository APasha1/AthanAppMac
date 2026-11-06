import AppKit
import SwiftUI

/// `AthanAppMac --snapshot <dir>` renders each island state to a PNG (used for design review).
@MainActor
enum Snapshot {
    static func run(to dir: String, store: PrayerStore, settings: AppSettings) {
        if !settings.hasLocation {
            settings.latitude = 40.7128; settings.longitude = -74.0060; settings.placeName = "New York, NY"
        }
        store.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)) // let the debounced recompute land
        let state = IslandState()
        state.metrics = NotchMetrics(width: 185, height: 32, hasNotch: true)

        func render(_ name: String, hovering: Bool, mode: IslandMode, height: CGFloat = 150) {
            state.hovering = hovering
            store.mode = mode
            let island = IslandView(openSettings: {})
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(state)
            // The island hanging from a mock menu bar over a wallpaper, as it looks on a real Mac.
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.45), Color(red: 0.42, green: 0.27, blue: 0.62),
                                        Color(red: 0.86, green: 0.47, blue: 0.52)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                MenuBarMock(height: state.metrics.height)
                island
            }
            .frame(width: 1120, height: height, alignment: .top)
            .clipped()
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }

        let p = store.currentPrayer?.prayer ?? .asr
        render("1-compact", hovering: false, mode: .compact, height: 100)
        render("2-expanded", hovering: true, mode: .compact, height: 280)
        render("3-alert", hovering: false, mode: .alert(p, deferred: false), height: 210)
        render("4-after-call", hovering: false, mode: .alert(p, deferred: true), height: 210)
        render("5-heads-up", hovering: false, mode: .peek(Peek(prayer: .maghrib, title: "Maghrib in 10 min",
                                                               subtitle: "at 6:03 PM", symbol: Prayer.maghrib.symbol)))
        render("7-ending-soon", hovering: false, mode: .peek(Peek(prayer: .asr, title: "Asr ends in 15 min",
                                                                  subtitle: "Not checked off yet · ends 6:03 PM",
                                                                  symbol: "hourglass", canMarkPrayed: true)))
        render("8-friday-dua", hovering: false, mode: .peek(Peek(prayer: .asr, title: "Friday: make dua now",
                                                                 subtitle: "Duas are accepted in this hour · until 5:55 PM",
                                                                 symbol: "sparkles", important: true)))
        render("6-meeting-nudge", hovering: false, mode: .peek(Peek(prayer: p, title: "Pray \(p.name) before Weekly Sync?",
                                                                    subtitle: "It starts in 9 min, and \(p.name) ends during it",
                                                                    symbol: "calendar.badge.clock")))
    }
}

/// A stand-in macOS menu bar for the README screenshots.
private struct MenuBarMock: View {
    let height: CGFloat

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
            Text("Finder").fontWeight(.bold)
            ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0) }
            Spacer()
            Image(systemName: "moon.stars.fill")
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: height)
        .background(Color.black.opacity(0.22))
    }
}
