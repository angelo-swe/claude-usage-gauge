// UsageAPI.swift
// Fetches Claude subscription usage from the official OAuth usage endpoint —
// the same endpoint Claude Code's `/usage` command uses.
//
//   GET https://api.anthropic.com/api/oauth/usage
//   Authorization: Bearer <claude code oauth access token>
//   anthropic-beta: oauth-2025-04-20
//   User-Agent: claude-code/<version>      (load-bearing — omit ⇒ 429)
//
// Read-only. No inference. No token rotation.

import Foundation

enum UsageFetch {
    case success(UsageSnapshot)
    case expired                  // 401/403 — token stale
    case failure(String)
}

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // Bump when the local Claude Code version changes. The endpoint
    // hard-rate-limits requests without a claude-code User-Agent.
    static let userAgent = "claude-code/2.1.197"

    // MARK: - Wire model

    private struct Response: Decodable {
        struct Window: Decodable {
            let utilization: Double
            let resets_at: String?
        }
        struct Extra: Decodable {
            let is_enabled: Bool?
            let monthly_limit: Double?
            let used_credits: Double?
            let utilization: Double?
        }
        let five_hour: Window?
        let seven_day: Window?
        let extra_usage: Extra?
    }

    // MARK: - Fetch

    static func fetch(token: String) async -> UsageFetch {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)",       forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20",       forHTTPHeaderField: "anthropic-beta")
        req.setValue(userAgent,                forHTTPHeaderField: "User-Agent")
        req.setValue("application/json",       forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure("No HTTP response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .expired
            }
            guard http.statusCode == 200 else {
                return .failure("HTTP \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return .success(snapshot(from: decoded))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Map wire → snapshot

    private static func snapshot(from r: Response) -> UsageSnapshot {
        func window(_ w: Response.Window?) -> UsageSnapshot.Window? {
            guard let w else { return nil }
            return UsageSnapshot.Window(utilization: w.utilization,
                                        resetsAt: parseDate(w.resets_at))
        }

        var credits: UsageSnapshot.Credits?
        if let e = r.extra_usage {
            // The API returns dollar amounts in cents (e.g. 5977 = $59.77).
            credits = UsageSnapshot.Credits(isEnabled: e.is_enabled ?? false,
                                            monthlyLimit: e.monthly_limit.map { $0 / 100 },
                                            usedCredits: e.used_credits.map { $0 / 100 },
                                            utilization: e.utilization)
        }

        return UsageSnapshot(fiveHour: window(r.five_hour),
                             sevenDay: window(r.seven_day),
                             credits: credits,
                             fetchedAt: Date(),
                             authState: .ok,
                             errorMessage: nil)
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
