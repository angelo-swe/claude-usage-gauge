// UsageMonitor.swift
// Owns the poll loop: reads the Keychain token, fetches usage from the
// official endpoint, writes the snapshot into the widget container, and tells
// WidgetKit to reload. Publishes state for the menu-bar UI.

import Foundation
import Combine
import WidgetKit

@MainActor
final class UsageMonitor: ObservableObject {

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false

    /// Poll interval in minutes (floor 3 min). Persisted in standard defaults.
    var pollMinutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "poll_interval_minutes")
            return v == 0 ? 5 : v
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "poll_interval_minutes")
            objectWillChange.send()
            restartTimer()
        }
    }

    private var timer: Timer?

    init() {
        loadCachedSnapshot()
    }

    func start() {
        Task { await refresh() }
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        let seconds = Double(max(3, pollMinutes)) * 60
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let result: UsageSnapshot
        switch KeychainCredentials.readToken() {
        case .ok(let token):
            switch await UsageAPI.fetch(token: token.accessToken) {
            case .success(let snap):   result = snap
            case .expired:             result = .failure(.expired)
            case .failure(let msg):    result = .failure(.error, msg)
            }
        case .expired:
            result = .failure(.expired)
        case .notFound:
            result = .failure(.notFound)
        case .error(let msg):
            result = .failure(.error, msg)
        }

        snapshot = result
        persist(result)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Widget hand-off (write into the widget's own container)

    private func persist(_ snap: UsageSnapshot) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        let url = Shared.widgetInboxURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: [])
    }

    private func loadCachedSnapshot() {
        guard let data = try? Data(contentsOf: Shared.widgetInboxURL),
              let snap = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else { return }
        snapshot = snap
    }
}
