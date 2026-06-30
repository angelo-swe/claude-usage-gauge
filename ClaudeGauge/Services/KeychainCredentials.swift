// KeychainCredentials.swift
// Reads the Claude Code OAuth token from the macOS login Keychain.
//
// Claude Code stores its credentials as a generic-password item:
//   service = "Claude Code-credentials", account = <username>
//   value   = JSON { "claudeAiOauth": { "accessToken", "expiresAt"(ms), ... } }
//
// This app only READS the token (read-only usage polling). It never
// writes, refreshes, or rotates it — Claude Code owns the token lifecycle.
//
// NOTE: the host app must be NON-sandboxed to read another app's Keychain
// item. The first read triggers a one-time macOS authorization prompt;
// choosing "Always Allow" silences it thereafter.

import Foundation
import Security

struct ClaudeCodeToken {
    let accessToken: String
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

enum KeychainResult {
    case ok(ClaudeCodeToken)
    case expired
    case notFound
    case error(String)
}

enum KeychainCredentials {
    static let service = "Claude Code-credentials"

    static func readToken() -> KeychainResult {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecMatchLimit as String:       kSecMatchLimitOne,
            kSecReturnData as String:       true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return .error("Keychain item had no data")
            }
            return parse(data)
        case errSecItemNotFound:
            return .notFound
        case errSecUserCanceled, errSecAuthFailed:
            return .error("Keychain access was denied")
        default:
            return .error("Keychain error \(status)")
        }
    }

    private static func parse(_ data: Data) -> KeychainResult {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            return .error("Could not parse Claude Code credentials")
        }

        var expires: Date?
        // expiresAt is a Unix timestamp in milliseconds.
        if let ms = oauth["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = oauth["expiresAt"] as? Int {
            expires = Date(timeIntervalSince1970: Double(ms) / 1000)
        }

        let cc = ClaudeCodeToken(accessToken: token, expiresAt: expires)
        return cc.isExpired ? .expired : .ok(cc)
    }
}
