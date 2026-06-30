// ClaudeGaugeWidget.swift
// The desktop WidgetKit widgets (Session / Weekly / Credits). Each is
// sandboxed and does NOT touch the network or Keychain — it only renders
// the snapshot the host app writes into this extension's own container.

import WidgetKit
import SwiftUI

// MARK: - Snapshot (must match host UsageModel.swift)

enum AuthState: String, Codable { case ok, expired, notFound, error }

struct UsageSnapshot: Codable {
    struct Window: Codable { var utilization: Double; var resetsAt: Date? }
    struct Credits: Codable {
        var isEnabled: Bool
        var monthlyLimit: Double?
        var usedCredits: Double?
        var utilization: Double?
    }
    var fiveHour: Window?
    var sevenDay: Window?
    var credits: Credits?
    var fetchedAt: Date
    var authState: AuthState
    var errorMessage: String?

    static let placeholder = UsageSnapshot(
        fiveHour: Window(utilization: 12, resetsAt: Date().addingTimeInterval(4 * 3600)),
        sevenDay: Window(utilization: 41, resetsAt: Date().addingTimeInterval(2 * 86400)),
        credits: Credits(isEnabled: true, monthlyLimit: 60, usedCredits: 18.40, utilization: 31),
        fetchedAt: Date(), authState: .ok, errorMessage: nil)
}

// MARK: - Window selection (per-instance picker)

enum GaugeWindow: String {
    case session, weekly, credits

    var title: String {
        switch self {
        case .session: return "SESSION"
        case .weekly:  return "WEEKLY"
        case .credits: return "CREDITS"
        }
    }

    /// Duration tag shown in parentheses on the widget header, per mode.
    var durationTag: String {
        switch self {
        case .session: return "5H"
        case .weekly:  return "7D"
        case .credits: return "$"
        }
    }

    /// Full header, e.g. "SESSION (5H)".
    var header: String { "\(title) (\(durationTag))" }
}

// MARK: - Timeline

struct GaugeEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    let window: GaugeWindow
}

// One provider per window — each widget hard-codes which window it shows, so
// there is no configuration intent to bind (robust; never silently reverts).
struct GaugeProvider: TimelineProvider {
    let window: GaugeWindow

    func placeholder(in context: Context) -> GaugeEntry {
        GaugeEntry(date: Date(), snapshot: .placeholder, window: window)
    }

    func getSnapshot(in context: Context, completion: @escaping (GaugeEntry) -> Void) {
        completion(GaugeEntry(date: Date(), snapshot: load(), window: window))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GaugeEntry>) -> Void) {
        let entry = GaugeEntry(date: Date(), snapshot: load(), window: window)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(180))))
    }

    private func load() -> UsageSnapshot {
        // The host writes the snapshot into this widget's own container Documents.
        guard
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("snapshot.json"),
            let data = try? Data(contentsOf: url),
            let snap = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        else {
            return UsageSnapshot.failureNotFound
        }
        return snap
    }
}

private extension UsageSnapshot {
    static let failureNotFound = UsageSnapshot(
        fiveHour: nil, sevenDay: nil, credits: nil,
        fetchedAt: Date(), authState: .notFound, errorMessage: nil)
}

// MARK: - Colors

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
    static func level(_ u: Double) -> Color {
        switch u {
        case ..<50:  return Color(hex: 0x34D399)   // emerald
        case ..<75:  return Color(hex: 0xFBBF24)   // amber
        case ..<90:  return Color(hex: 0xFB923C)   // orange
        default:     return Color(hex: 0xF87171)   // red
        }
    }
}

// MARK: - Arc gauge

/// Draws the gauge arc(s). `showTrack == false` draws only the value arc — used
/// as the blurred glow layer behind the crisp one.
private struct GaugeCanvas: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat
    var showTrack: Bool

    var body: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let inset = lineWidth / 2 + 1
            let rect = CGRect(x: (size.width - side) / 2 + inset,
                              y: (size.height - side) / 2 + inset,
                              width: side - inset * 2, height: side - inset * 2)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2
            let start = 145.0, sweep = 250.0

            if showTrack {
                var track = Path()
                track.addArc(center: center, radius: radius, startAngle: .degrees(start),
                             endAngle: .degrees(start + sweep), clockwise: false)
                ctx.stroke(track, with: .color(.white.opacity(0.10)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            let p = max(0, min(1, progress))
            var value = Path()
            value.addArc(center: center, radius: radius, startAngle: .degrees(start),
                         endAngle: .degrees(start + sweep * p), clockwise: false)
            ctx.stroke(value, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }
}

/// Self-scaling gauge: stroke weight and glow are proportional to its rendered
/// size, so the exact same look holds at every widget family.
private struct ArcGauge: View {
    var progress: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let lw = side * 0.10
            ZStack {
                GaugeCanvas(progress: progress, color: color, lineWidth: lw, showTrack: false)
                    .blur(radius: side * 0.07)
                    .opacity(0.9)
                GaugeCanvas(progress: progress, color: color, lineWidth: lw, showTrack: true)
                    .shadow(color: color.opacity(0.55), radius: side * 0.035)
            }
        }
    }
}

// MARK: - Resolved view data

private struct WindowVM {
    let utilization: Double
    let subtitle: String    // line under the gauge
    let available: Bool
}

private func resolve(_ snap: UsageSnapshot, _ window: GaugeWindow) -> WindowVM {
    switch window {
    case .session:
        return WindowVM(utilization: snap.fiveHour?.utilization ?? 0,
                        subtitle: resetText(snap.fiveHour?.resetsAt),
                        available: snap.fiveHour != nil)
    case .weekly:
        return WindowVM(utilization: snap.sevenDay?.utilization ?? 0,
                        subtitle: resetText(snap.sevenDay?.resetsAt),
                        available: snap.sevenDay != nil)
    case .credits:
        let c = snap.credits
        let sub: String
        if let used = c?.usedCredits, let limit = c?.monthlyLimit {
            sub = String(format: "$%.2f / $%.0f", used, limit)
        } else { sub = "—" }
        return WindowVM(utilization: c?.utilization ?? 0,
                        subtitle: sub,
                        available: (c?.isEnabled ?? false))
    }
}

private func resetText(_ date: Date?) -> String {
    guard let date else { return "" }
    let secs = date.timeIntervalSinceNow
    if secs <= 0 { return "resetting…" }
    let h = Int(secs) / 3600
    if h >= 24 { return "resets \(h / 24)d \(h % 24)h" }
    if h >= 1  { return "resets \(h)h \(Int(secs) % 3600 / 60)m" }
    return "resets \(Int(secs) / 60)m"
}

// MARK: - Widget views

struct GaugeWidgetView: View {
    @Environment(\.widgetFamily) var family
    var entry: GaugeEntry

    var body: some View {
        Group {
            switch entry.snapshot.authState {
            case .ok:        gauges
            case .expired:   message("Token expired", "Run Claude Code to refresh")
            case .notFound:  message("Not signed in", "Sign in with Claude Code")
            case .error:     message("Unavailable", entry.snapshot.errorMessage ?? "Try again")
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(hex: 0x1C1C1F), Color(hex: 0x111114)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder private var gauges: some View {
        // One design for every size — the small hero gauge, scaled up. The gauge
        // itself self-scales; `s` scales the header/subtitle/padding chrome.
        switch family {
        case .systemLarge:  gaugeFace(s: 1.7)
        case .systemSmall:  gaugeFace(s: 1.0)
        default:            gaugeFace(s: 1.3)   // medium
        }
    }

    private func gaugeFace(s: CGFloat) -> some View {
        let vm = resolve(entry.snapshot, entry.window)
        let color = Color.level(vm.utilization)
        let three = Int(vm.utilization.rounded()) >= 100
        return VStack(spacing: 0) {
            Text(entry.window.header)
                .font(.system(size: 10 * s, weight: .bold, design: .rounded))
                .tracking(1.1 * s)
                .foregroundStyle(.white.opacity(0.40))
                .minimumScaleFactor(0.8)
                .lineLimit(1)
            Spacer(minLength: 6 * s)
            ZStack {
                ArcGauge(progress: vm.utilization / 100, color: color)
                // Number is proportional to the gauge's actual rendered size.
                GeometryReader { g in
                    let d = min(g.size.width, g.size.height)
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(vm.available ? "\(Int(vm.utilization.rounded()))" : "—")
                            .font(.system(size: d * (three ? 0.24 : 0.30), weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                        Text(vm.available ? "%" : "")
                            .font(.system(size: d * (three ? 0.11 : 0.13), weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                            .baselineOffset(d * 0.02)
                    }
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                    .frame(width: g.size.width, height: g.size.height)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Text(vm.available ? vm.subtitle : "not enabled")
                .font(.system(size: 10.5 * s, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
        }
        .padding(.horizontal, 12 * s)
        .padding(.vertical, 14 * s)
    }

    private func message(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.6))
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(sub)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(12)
    }

}

// MARK: - Widgets (one per window — no configuration to break)

private func gaugeWidget(kind: String, window: GaugeWindow,
                         name: String, desc: String) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: GaugeProvider(window: window)) { entry in
        GaugeWidgetView(entry: entry)
    }
    .configurationDisplayName(name)
    .description(desc)
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    .contentMarginsDisabled()
}

struct SessionWidget: Widget {
    var body: some WidgetConfiguration {
        gaugeWidget(kind: "ClaudeGaugeSession", window: .session,
                    name: "Claude — Session (5h)", desc: "Your rolling 5-hour session usage.")
    }
}

struct WeeklyWidget: Widget {
    var body: some WidgetConfiguration {
        gaugeWidget(kind: "ClaudeGaugeWeekly", window: .weekly,
                    name: "Claude — Weekly (7d)", desc: "Your weekly usage across all models.")
    }
}

struct CreditsWidget: Widget {
    var body: some WidgetConfiguration {
        gaugeWidget(kind: "ClaudeGaugeCredits", window: .credits,
                    name: "Claude — Credits ($)", desc: "Your pay-as-you-go credit spend.")
    }
}

@main
struct ClaudeGaugeBundle: WidgetBundle {
    var body: some Widget {
        SessionWidget()
        WeeklyWidget()
        CreditsWidget()
    }
}
