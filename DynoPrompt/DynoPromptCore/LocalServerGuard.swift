//
//  LocalServerGuard.swift
//  DynoPromptCore
//
//  Request validation for DynoPrompt's two local servers (Remote Connection and
//  Director Mode).
//
//  Threat model
//  ------------
//  Both servers bind to every interface so a phone on the same Wi-Fi can reach
//  them. That also makes them reachable by:
//
//    1. Any browser page the user has open. A page cannot *read* a cross-origin
//       HTTP response, but `new WebSocket("ws://localhost:7374")` is NOT
//       subject to the same-origin policy — the connection succeeds and the
//       page receives every frame. Without a check, any website could silently
//       stream the user's script and live microphone transcript.
//
//    2. DNS rebinding. An attacker's page loaded from `evil.test` re-resolves
//       that name to 127.0.0.1. The browser now considers requests to
//       `http://evil.test:7575` same-origin, so the page *can* read the
//       response — including the Director page's embedded auth token — and
//       then drive the teleprompter.
//
//  Both are defeated by checking which name the client used to reach us (Host)
//  and which page is asking (Origin), which is what this type does.
//

import Foundation

public enum LocalServerGuard {

    /// Hostnames that legitimately address this machine. Anything else in a
    /// Host header means the request arrived via a name we do not control,
    /// which is the signature of DNS rebinding.
    static let loopbackNames: Set<String> = [
        "localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0",
    ]

    /// Splits a `Host`/`Origin` authority into host and optional port,
    /// handling bracketed IPv6 literals.
    static func splitAuthority(_ authority: String) -> (host: String, port: UInt16?) {
        let trimmed = authority.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return ("", nil) }

        if trimmed.hasPrefix("[") {
            guard let closing = trimmed.firstIndex(of: "]") else { return (trimmed, nil) }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            let rest = trimmed[trimmed.index(after: closing)...]
            if rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) {
                return (host, port)
            }
            return (host, nil)
        }

        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, let port = UInt16(parts[1]) {
            return (String(parts[0]), port)
        }
        return (trimmed, nil)
    }

    /// True when `host` names this machine: loopback, a literal IPv4/IPv6
    /// address assigned to one of our interfaces, or a `.local` Bonjour name.
    public static func isSelfAddressed(host: String, localAddresses: Set<String>) -> Bool {
        let normalized = host.lowercased()
        guard !normalized.isEmpty else { return false }
        if loopbackNames.contains(normalized) { return true }
        if localAddresses.contains(normalized) { return true }
        // A bare `.local` name is resolved by mDNS, which an off-network
        // attacker cannot spoof into pointing at us.
        if normalized.hasSuffix(".local") { return true }
        return false
    }

    /// Validates an HTTP request's `Host` header.
    ///
    /// - Parameters:
    ///   - headers: parsed request headers, lowercased keys.
    ///   - expectedPort: the port this server listens on.
    ///   - localAddresses: IP literals currently assigned to this machine.
    public static func isAcceptableHost(
        headers: [String: String],
        expectedPort: UInt16,
        localAddresses: Set<String>
    ) -> Bool {
        // A request with no Host header is HTTP/1.0 or hand-rolled; it cannot
        // have come from a browser, so rebinding does not apply.
        guard let hostHeader = headers["host"] else { return true }
        let (host, port) = splitAuthority(hostHeader)
        guard isSelfAddressed(host: host, localAddresses: localAddresses) else { return false }
        // A mismatched port means the name was resolved for a different
        // service; reject rather than guess.
        if let port, port != expectedPort { return false }
        return true
    }

    /// Validates an `Origin` header for either an HTTP request or a WebSocket
    /// handshake.
    ///
    /// A missing Origin means a native client (curl, a Python director script,
    /// DynoPrompt's own iOS app) — allowed, because those are not driven by a
    /// hostile page and are still gated by the auth token. A *present* Origin
    /// means a browser page is asking, and it is only allowed when that page
    /// was served by this very server.
    public static func isAcceptableOrigin(
        headers: [String: String],
        allowedPorts: Set<UInt16>,
        localAddresses: Set<String>
    ) -> Bool {
        guard let origin = headers["origin"]?.trimmingCharacters(in: .whitespaces),
              !origin.isEmpty else { return true }

        // `null` is what a sandboxed iframe or a file:// page sends. Never
        // trust it.
        guard origin.lowercased() != "null" else { return false }

        guard let components = URLComponents(string: origin),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return false }

        guard scheme == "http" || scheme == "https" else { return false }
        guard isSelfAddressed(host: host, localAddresses: localAddresses) else { return false }

        let port = components.port.map { UInt16(truncatingIfNeeded: $0) }
            ?? (scheme == "https" ? 443 : 80)
        return allowedPorts.contains(port)
    }

    /// Parses a raw HTTP request head into a method, target and lowercased
    /// headers. Returns nil for anything that is not a well-formed request.
    public static func parseRequestHead(_ raw: String) -> (method: String, target: String, headers: [String: String])? {
        // Only the head matters; stop at the blank line.
        let head = raw.components(separatedBy: "\r\n\r\n").first ?? raw
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            // First header wins; a duplicated Host is a smuggling attempt.
            if headers[key] == nil { headers[key] = value }
        }
        return (method, target, headers)
    }

    /// Constant-time comparison for auth tokens, so a network attacker cannot
    /// recover a token by timing repeated guesses.
    public static func secureCompare(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count {
            difference |= a[i] ^ b[i]
        }
        return difference == 0
    }
}
