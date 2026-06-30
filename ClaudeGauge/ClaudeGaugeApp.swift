// ClaudeGaugeApp.swift
// Menu-bar agent (LSUIElement). No windows — it polls usage in the
// background, feeds the desktop widget, and exposes a small status menu.

import SwiftUI
import ServiceManagement

@main
struct ClaudeGaugeApp: App {
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: monitor)
        } label: {
            Image(systemName: "gauge.with.dots.needle.50percent")
        }
        .menuBarExtraStyle(.menu)
    }

    init() {
        // Defer start to the next runloop so @StateObject is ready.
        let m = monitor
        DispatchQueue.main.async { m.start() }
    }
}

private struct MenuContentView: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        statusSection

        Divider()

        Button(monitor.isRefreshing ? "Refreshing…" : "Refresh now") {
            Task { await monitor.refresh() }
        }
        .disabled(monitor.isRefreshing)

        Menu("Poll interval") {
            ForEach([3, 5, 15, 30, 60], id: \.self) { mins in
                Button {
                    monitor.pollMinutes = mins
                } label: {
                    Text(mins == monitor.pollMinutes ? "✓ \(label(mins))" : label(mins))
                }
            }
        }

        Toggle("Launch at Login", isOn: launchAtLoginBinding)

        Divider()

        Button("Quit Claude Gauge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    // MARK: - Status

    @ViewBuilder private var statusSection: some View {
        if let snap = monitor.snapshot {
            switch snap.authState {
            case .ok:
                if let w = snap.fiveHour { Text(row("Session", w.utilization, w.resetsAt)) }
                if let w = snap.sevenDay { Text(row("Weekly", w.utilization, w.resetsAt)) }
                if let c = snap.credits, c.isEnabled {
                    Text(creditsRow(c))
                }
                Text("Updated \(relative(snap.fetchedAt))").foregroundStyle(.secondary)
            case .expired:
                Text("Token expired — run Claude Code to refresh")
            case .notFound:
                Text("Claude Code not signed in")
            case .error:
                Text("Error: \(snap.errorMessage ?? "unknown")")
            }
        } else {
            Text("Loading usage…").foregroundStyle(.secondary)
        }
    }

    private func row(_ name: String, _ util: Double, _ resets: Date?) -> String {
        let pct = "\(Int(util.rounded()))%"
        if let resets { return "\(name): \(pct)  ·  resets \(relative(resets))" }
        return "\(name): \(pct)"
    }

    private func creditsRow(_ c: UsageSnapshot.Credits) -> String {
        if let used = c.usedCredits, let limit = c.monthlyLimit {
            return String(format: "Credits: $%.2f / $%.2f", used, limit)
        }
        if let u = c.utilization { return "Credits: \(Int(u.rounded()))%" }
        return "Credits: —"
    }

    private func label(_ mins: Int) -> String {
        mins >= 60 ? "1 hour" : "\(mins) min"
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Launch at login

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { want in
                do {
                    if want { try SMAppService.mainApp.register() }
                    else    { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("Launch-at-login toggle failed: \(error)")
                }
            }
        )
    }
}
