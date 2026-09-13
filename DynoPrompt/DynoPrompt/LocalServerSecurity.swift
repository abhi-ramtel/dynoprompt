//
//  LocalServerSecurity.swift
//  DynoPrompt
//
//  Shared hardening for the two local servers (Remote Connection, Director
//  Mode). The decision logic lives in `LocalServerGuard` (DynoPromptCore) so it
//  can be unit tested; this file is the thin Network.framework binding.
//

import Foundation
import Network

enum LocalServerSecurity {

    /// Largest HTTP request head we will buffer. A request bigger than this is
    /// not a browser asking for a page, so we drop the connection instead of
    /// growing a buffer for it.
    static let maxRequestBytes = 16 * 1024

    /// IP literals currently assigned to this machine, used to decide whether a
    /// `Host`/`Origin` header actually names us.
    ///
    /// Recomputed per request rather than cached: the set changes when the
    /// user moves between networks mid-session, and a stale cache would lock
    /// out the phone they just reconnected.
    static func localAddresses() -> Set<String> {
        var addresses: Set<String> = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addresses }
        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let family = pointer.pointee.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                pointer.pointee.ifa_addr,
                socklen_t(pointer.pointee.ifa_addr.pointee.sa_len),
                &hostname, socklen_t(hostname.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }

            var ip = String(cString: hostname).lowercased()
            // Strip the IPv6 scope suffix ("fe80::1%en0") so it compares
            // equal to what a browser would put in a Host header.
            if let percent = ip.firstIndex(of: "%") {
                ip = String(ip[ip.startIndex..<percent])
            }
            addresses.insert(ip)
        }
        return addresses
    }

    /// Builds WebSocket options that reject a handshake from a foreign page.
    ///
    /// WebSocket connections are exempt from the same-origin policy: any site
    /// the user has open can open a socket to `ws://localhost:<port>` and read
    /// everything we broadcast. Checking `Origin` at the handshake is the only
    /// place we can stop that before frames start flowing.
    static func websocketOptions(allowedPorts: Set<UInt16>) -> NWProtocolWebSocket.Options {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(.main) { subprotocols, headers in
            let map = Dictionary(
                headers.map { ($0.name.lowercased(), $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            let accepted = LocalServerGuard.isAcceptableOrigin(
                headers: map,
                allowedPorts: allowedPorts,
                localAddresses: localAddresses()
            )
            guard accepted else {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: subprotocols.first)
        }
        return options
    }

    /// Validates an HTTP request head for a server listening on `port`.
    /// Returns nil when the request should be answered, or an HTTP response to
    /// send and close on.
    static func rejectionResponse(
        forRequest raw: String,
        port: UInt16,
        allowedOriginPorts: Set<UInt16>
    ) -> Data? {
        guard let request = LocalServerGuard.parseRequestHead(raw) else {
            return errorResponse(status: "400 Bad Request", message: "Malformed request.")
        }

        // Only reads are meaningful: these servers expose a single page.
        guard request.method == "GET" || request.method == "HEAD" else {
            return errorResponse(status: "405 Method Not Allowed", message: "Method not allowed.")
        }

        let addresses = localAddresses()

        // Defeats DNS rebinding: a browser that reached us through an
        // attacker-controlled name sends that name in Host.
        guard LocalServerGuard.isAcceptableHost(
            headers: request.headers,
            expectedPort: port,
            localAddresses: addresses
        ) else {
            return errorResponse(
                status: "403 Forbidden",
                message: "Host not permitted. Connect using this Mac's address directly."
            )
        }

        guard LocalServerGuard.isAcceptableOrigin(
            headers: request.headers,
            allowedPorts: allowedOriginPorts,
            localAddresses: addresses
        ) else {
            return errorResponse(status: "403 Forbidden", message: "Cross-origin request refused.")
        }

        return nil
    }

    static func errorResponse(status: String, message: String) -> Data {
        let body = Data(message.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.count)\r
        \(securityHeaders)\r
        Connection: close\r
        \r\n
        """
        return Data(header.utf8) + body
    }

    /// Response headers applied to every page we serve.
    ///
    /// The CSP matters: both pages are entirely self-contained (inline style
    /// and script, no images, no fonts, no third-party anything), so locking
    /// them to `'self'` plus inline means a future edit that introduces a
    /// remote resource — or an injection that tries to — simply will not load.
    static let securityHeaders = """
    Cache-Control: no-store\r
    X-Content-Type-Options: nosniff\r
    X-Frame-Options: DENY\r
    Referrer-Policy: no-referrer\r
    Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src ws: wss:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'
    """

    static func pageResponse(html: String) -> Data {
        let body = Data(html.utf8)
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        \(securityHeaders)\r
        Connection: close\r
        \r\n
        """
        return Data(header.utf8) + body
    }

    /// 32 bytes of CSPRNG output, hex encoded.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // Never fall back to a weak source — a predictable token is worse
            // than a disabled server.
            return ""
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
