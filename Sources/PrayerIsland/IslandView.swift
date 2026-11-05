import SwiftUI

// MARK: - Shape

/// The notch silhouette: flares into the top edge of the screen and rounds at the bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, (r.height - t) / 1.2, r.width / 3)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

extension Prayer {
    var tint: [Color] {
        switch self {
        case .fajr: [Color(red: 0.55, green: 0.55, blue: 1.0), Color(red: 1.0, green: 0.6, blue: 0.75)]
        case .sunrise: [Color(red: 1.0, green: 0.62, blue: 0.3), Color(red: 1.0, green: 0.85, blue: 0.4)]
        case .dhuhr: [Color(red: 1.0, green: 0.84, blue: 0.3), Color(red: 1.0, green: 0.95, blue: 0.6)]
        case .asr: [Color(red: 1.0, green: 0.7, blue: 0.25), Color(red: 1.0, green: 0.85, blue: 0.45)]
        case .maghrib: [Color(red: 1.0, green: 0.45, blue: 0.35), Color(red: 1.0, green: 0.65, blue: 0.45)]
        case .isha: [Color(red: 0.5, green: 0.55, blue: 1.0), Color(red: 0.75, green: 0.6, blue: 1.0)]
        }
    }
    var gradient: LinearGradient { LinearGradient(colors: tint, startPoint: .bottomLeading, endPoint: .topTrailing) }
}

// MARK: - Root

struct IslandView: View {
    @EnvironmentObject var store: PrayerStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var state: IslandState
    let openSettings: () -> Void

    private var spring: Animation { .spring(response: 0.45, dampingFraction: 0.78) }

    var body: some View {
        let layout = state.layout(for: store)
        let size = state.size(for: layout, showWings: settings.showWings)
        let n = state.metrics
        let open = layout == .expanded || layout == .alert || layout == .peek

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: open ? 14 : 6, bottomRadius: open ? 30 : (n.hasNotch ? 10 : 12))
                    .fill(.black)
                    .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 18, y: 8)

                content(layout)
                    .padding(.horizontal, open ? 14 + 14 : 6)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipShape(NotchShape(topRadius: open ? 14 : 6, bottomRadius: open ? 30 : 10))
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture {
                // Click the notch to open; click a glance to open the full view.
                if layout == .compact || layout == .peek { state.hovering = true }
            }
            .padding(.top, n.hasNotch ? 0 : 2)
            Spacer(minLength: 0)
        }
        .frame(width: IslandState.canvas.width, height: IslandState.canvas.height, alignment: .top)
        .animation(spring, value: layout)
        .animation(spring, value: store.mode)
        .animation(spring, value: n)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func content(_ layout: IslandState.Layout) -> some View {
        switch layout {
        case .hidden:
            Color.clear
        case .compact:
            CompactWings()
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        case .peek:
            if case .peek(let peek) = store.mode {
                PeekView(peek: peek)
                    .padding(.top, state.metrics.height)
                    .transition(.blurReplace)
            }
        case .expanded:
            ExpandedView(openSettings: openSettings)
                .padding(.top, state.metrics.height)
                .transition(.blurReplace)
        case .alert:
            if case .alert(let p, let deferred) = store.mode {
                AlertView(prayer: p, deferred: deferred)
                    .padding(.top, state.metrics.height)
                    .transition(.blurReplace)
            }
        }
    }
}

// MARK: - Compact

struct CompactWings: View {
    @EnvironmentObject var store: PrayerStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var state: IslandState

    var body: some View {
        HStack(spacing: 0) {
            if settings.showWings, let next = store.next {
                HStack(spacing: 6) {
                    Image(systemName: next.prayer.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(next.prayer.gradient)
                        .symbolRenderingMode(.hierarchical)
                    Text(next.prayer.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    if let cur = store.currentPrayer, store.needsReminder(cur.prayer, on: cur.start) {
                        Circle().fill(Color.orange).frame(width: 5, height: 5)
                            .help("\(cur.prayer.name) not yet prayed")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)

                Spacer().frame(width: state.metrics.width)

                Text(countdown(to: next.time))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    .contentTransition(.numericText(countsDown: true))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
            } else if !settings.hasLocation {
                Text("Set location")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: state.metrics.height)
    }

    private func countdown(to date: Date) -> String {
        let left = date.timeIntervalSince(store.now)
        return left >= 3600 ? PrayerStore.short(left) : PrayerStore.clock(left)
    }
}

// MARK: - Peek

struct PeekView: View {
    @EnvironmentObject var store: PrayerStore
    let peek: Peek

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: peek.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(peek.prayer.gradient)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text(peek.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(peek.subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if peek.canMarkPrayed {
                Button { store.markPrayed(peek.prayer); store.dismissAlert() } label: {
                    Label("Prayed", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(peek.prayer.gradient))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @EnvironmentObject var store: PrayerStore
    @EnvironmentObject var settings: AppSettings
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ProgressCapsule(value: store.progressToNext, tint: store.next?.prayer.tint ?? [.white])
                .frame(height: 4)
            timeline
            footer
        }
        .padding(.top, 10)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if let next = store.next {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next prayer")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(next.prayer.name)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("in \(PrayerStore.short(next.time.timeIntervalSince(store.now)))")
                            .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(next.prayer.gradient)
                            .contentTransition(.numericText(countsDown: true))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(next.prayer.arabic)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(next.time.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
            } else {
                Text("Set your location in Settings")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
            }
        }
    }

    private var timeline: some View {
        HStack(spacing: 6) {
            ForEach(store.slots) { slot in
                PrayerChip(slot: slot)
                    .onTapGesture {
                        if slot.prayer.isObligatory && slot.state != .upcoming { store.togglePrayed(slot.prayer) }
                    }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.fill").font(.system(size: 9))
            Text(settings.placeName.isEmpty ? "Unknown location" : settings.placeName)
            Text("·")
            Text(store.hijriDate)
            Spacer()
            if store.isPaused {
                Label("Paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
            }
            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.45))
        .lineLimit(1)
    }
}

struct PrayerChip: View {
    let slot: PrayerSlot
    @State private var hover = false

    var body: some View {
        let current = slot.state == .current
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: slot.prayer.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(slot.state == .past && !current ? AnyShapeStyle(.white.opacity(0.35)) : AnyShapeStyle(slot.prayer.gradient))
                    .frame(height: 18)
                if slot.prayed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green, .black)
                        .offset(x: 7, y: -4)
                }
            }
            Text(slot.prayer.name)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(current ? 1 : 0.6))
            Text(slot.time.formatted(.dateTime.hour().minute()))
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(current ? 0.95 : 0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(current ? AnyShapeStyle(LinearGradient(colors: slot.prayer.tint.map { $0.opacity(0.22) },
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(.white.opacity(hover ? 0.08 : 0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(current ? slot.prayer.tint[0].opacity(0.5) : .clear, lineWidth: 1)
        )
        .onHover { hover = $0 }
        .help(slot.prayer.isObligatory && slot.state != .upcoming ? (slot.prayed ? "Mark as not prayed" : "Mark as prayed") : "")
    }
}

struct ProgressCapsule: View {
    let value: Double
    let tint: [Color]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: tint, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * value))
            }
        }
    }
}

// MARK: - Alert

struct AlertView: View {
    @EnvironmentObject var store: PrayerStore
    let prayer: Prayer
    let deferred: Bool
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(prayer.gradient)
                        .opacity(0.25)
                        .scaleEffect(pulse ? 1.35 : 0.95)
                        .opacity(pulse ? 0 : 1)
                    Circle().fill(.white.opacity(0.08))
                    Image(systemName: prayer.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(prayer.gradient)
                        .symbolEffect(.bounce, value: pulse)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(deferred ? "Time for \(prayer.name)" : prayer.name)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(prayer.arabic)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(prayer.gradient)
                    }
                    Text(subtitle)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if store.player.isPlaying {
                    IconButton(symbol: "speaker.slash.fill", help: "Stop athan") { store.stopAthan() }
                }
                IconButton(symbol: "xmark", help: "Dismiss") { store.dismissAlert() }
            }

            HStack(spacing: 8) {
                PillButton(title: "Prayed", symbol: "checkmark", prominent: true, tint: prayer.tint) { store.markPrayed(prayer) }
                PillButton(title: "In 10 min", symbol: "clock.arrow.circlepath", prominent: false, tint: prayer.tint) { store.snooze(prayer) }
            }
        }
        .padding(.top, 10)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    private var subtitle: String {
        guard let start = store.today[prayer] else { return "" }
        let ends = store.currentPrayer.map { " · ends \($0.end.formatted(date: .omitted, time: .shortened))" } ?? ""
        if deferred {
            if let busy = store.busySince, start >= busy {
                return "Began \(PrayerStore.short(store.now.timeIntervalSince(start))) ago, during your call\(ends)"
            }
            let left = store.currentPrayer.map { PrayerStore.short($0.end.timeIntervalSince(store.now)) } ?? ""
            return "Not checked off yet · \(left) left\(ends)"
        }
        return "It's time to pray · \(start.formatted(date: .omitted, time: .shortened))\(ends)"
    }
}

struct PillButton: View {
    let title: String
    let symbol: String
    let prominent: Bool
    let tint: [Color]
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(prominent ? .black : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    Capsule().fill(prominent
                                   ? AnyShapeStyle(LinearGradient(colors: tint, startPoint: .leading, endPoint: .trailing))
                                   : AnyShapeStyle(.white.opacity(hover ? 0.16 : 0.1)))
                )
                .brightness(prominent && hover ? 0.06 : 0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hover ? 0.18 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
