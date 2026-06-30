// UsageModel.swift
// Shared model + constants for Claude Gauge.
//
// This snapshot is what the host app writes into the widget's container and the
// widget extension reads back. Keep it in sync with the copy in
// ClaudeGaugeExtension/ClaudeGaugeWidget.swift (the two targets do not
// share code).

import Foundation
import SwiftUI

// MARK: - Host → widget hand-off

enum Shared {
    /// The widget extension's bundle id.
    static let widgetBundleID = "com.angelotrifanoff.claudegauge.widget"

    /// We hand the snapshot to the widget by writing it straight into the
    /// widget extension's own sandbox container Documents folder. The widget
    /// reads its own container freely — which sidesteps the App Group +
    /// sandbox file-provenance issues that block a non-sandboxed host from
    /// sharing a file a sandboxed widget can open. The host (non-sandboxed)
    /// can write anywhere under the user's home.
    static var widgetInboxURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/\(widgetBundleID)/Data/Documents/snapshot.json")
    }
}

// MARK: - Auth state

enum AuthState: String, Codable {
    case ok           // token read + fetch succeeded
    case expired      // token past expiry or API returned 401/403
    case notFound     // no Claude Code credentials in Keychain
    case error        // network / decode / other failure
}

// MARK: - Snapshot (host → widget container → widget)

struct UsageSnapshot: Codable {
    struct Window: Codable {
        var utilization: Double      // 0–100
        var resetsAt: Date?
    }
    struct Credits: Codable {
        var isEnabled: Bool
        var monthlyLimit: Double?    // $
        var usedCredits: Double?     // $
        var utilization: Double?     // 0–100
    }

    var fiveHour: Window?
    var sevenDay: Window?
    var credits: Credits?
    var fetchedAt: Date
    var authState: AuthState
    var errorMessage: String?

    static func failure(_ state: AuthState, _ message: String? = nil) -> UsageSnapshot {
        UsageSnapshot(fiveHour: nil, sevenDay: nil, credits: nil,
                      fetchedAt: Date(), authState: state, errorMessage: message)
    }
}

// MARK: - Usage level (color bands)

enum UsageLevel {
    case healthy, moderate, high, critical

    init(_ utilization: Double) {
        switch utilization {
        case ..<50:  self = .healthy
        case ..<75:  self = .moderate
        case ..<90:  self = .high
        default:     self = .critical
        }
    }

    var label: String {
        switch self {
        case .healthy:  return "HEALTHY"
        case .moderate: return "MODERATE"
        case .high:     return "HIGH"
        case .critical: return "NEAR LIMIT"
        }
    }
}
